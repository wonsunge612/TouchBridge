import CoreGraphics
import Foundation
import IOKit

/// 외장 모니터 DDC/CI (밝기·명암·음량 등 모니터 OSD 설정을 영상 케이블로 읽고 쓰기).
/// Apple Silicon 에서는 비공개 IOAVService 로 I²C 를 주고받는다 (MonitorControl 등과 같은 방식).
/// 함수는 실행 시 dlsym 으로 찾는다 — 직접 링크하면 이 함수가 없는 Intel 맥에서 앱이 실행되지 않는다.
///
/// 모든 호출은 DDC.queue 에서 한다 (I²C 대기 때문에 수십~수백 ms 걸림).
enum DDC {
    static let queue = DispatchQueue(label: "TouchBridge.ddc", qos: .utility)

    private typealias CreateFn = @convention(c) (CFAllocator?, io_service_t) -> Unmanaged<CFTypeRef>?
    fileprivate typealias I2CFn = @convention(c) (CFTypeRef, UInt32, UInt32, UnsafeMutableRawPointer, UInt32) -> IOReturn

    private static let handle = dlopen(nil, RTLD_NOW)
    private static let createFn: CreateFn? = sym("IOAVServiceCreateWithService")
    fileprivate static let readFn: I2CFn? = sym("IOAVServiceReadI2C")
    fileprivate static let writeFn: I2CFn? = sym("IOAVServiceWriteI2C")

    private static func sym<T>(_ name: String) -> T? {
        guard let p = dlsym(handle, name) else { return nil }
        return unsafeBitCast(p, to: T.self)
    }

    static var isAvailable: Bool { createFn != nil && readFn != nil && writeFn != nil }

    /// 같은 화면에는 같은 채널 객체를 돌려줌 — '쓰기 후 읽기 대기' 같은 타이밍을 모든 사용처가 공유하도록
    private static var cache: [CGDirectDisplayID: DDCChannel] = [:]

    /// 외장 디스플레이 ID → DDC 채널.
    /// IORegistry 에서 AppleCLCD2(화면 EDID 정보) 다음에 나오는 외장 DCPAVServiceProxy 가 그 화면의 DDC 통로다.
    static func channels() -> [CGDirectDisplayID: DDCChannel] {
        guard let create = createFn else { return [:] }
        struct Found { let vendor: Int?, product: Int?, serial: Int?, service: CFTypeRef, entryID: UInt64 }
        var found: [Found] = []
        var it: io_iterator_t = 0
        guard IORegistryCreateIterator(kIOMainPortDefault, kIOServicePlane,
                                       IOOptionBits(kIORegistryIterateRecursively), &it) == KERN_SUCCESS else { return [:] }
        defer { IOObjectRelease(it) }
        var last: [String: Any]?
        while case let e = IOIteratorNext(it), e != 0 {
            defer { IOObjectRelease(e) }
            let cls = IOObjectCopyClass(e).takeRetainedValue() as String
            if cls.hasPrefix("AppleCLCD2") || cls == "IOMobileFramebufferShim" {
                if let da = prop(e, "DisplayAttributes") as? [String: Any],
                   let pa = da["ProductAttributes"] as? [String: Any] { last = pa }
            } else if cls == "DCPAVServiceProxy", (prop(e, "Location") as? String) == "External",
                      let av = create(kCFAllocatorDefault, e)?.takeRetainedValue() {
                var entryID: UInt64 = 0
                IORegistryEntryGetRegistryEntryID(e, &entryID)
                found.append(Found(vendor: (last?["LegacyManufacturerID"] as? NSNumber)?.intValue,
                                   product: (last?["ProductID"] as? NSNumber)?.intValue,
                                   serial: (last?["SerialNumber"] as? NSNumber)?.intValue,
                                   service: av, entryID: entryID))
                last = nil
            }
        }

        var count: UInt32 = 0
        CGGetActiveDisplayList(0, nil, &count)
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetActiveDisplayList(count, &ids, &count)
        let externals = ids.prefix(Int(count)).filter { CGDisplayIsBuiltin($0) == 0 }

        var result: [CGDirectDisplayID: DDCChannel] = [:]
        var unused = found
        for id in externals {
            let v = Int(CGDisplayVendorNumber(id)), m = Int(CGDisplayModelNumber(id)), s = Int(CGDisplaySerialNumber(id))
            if let i = unused.firstIndex(where: { $0.vendor == v && $0.product == m && (s == 0 || $0.serial == nil || $0.serial == s) }) {
                let f = unused.remove(at: i)
                result[id] = DDCChannel(displayID: id, service: f.service, entryID: f.entryID)
            }
        }
        // EDID 정보로 못 짝지었지만 남은 게 하나씩이면 그 둘을 짝지음
        let left = externals.filter { result[$0] == nil }
        if left.count == 1, unused.count == 1 {
            result[left[0]] = DDCChannel(displayID: left[0], service: unused[0].service, entryID: unused[0].entryID)
        }
        // 같은 통로면 쓰던 채널을 계속 사용 (DDC.queue 에서만 호출). 모니터를 껐다 켜면 화면 번호는 같아도
        // 통로가 새로 생기므로 레지스트리 ID까지 같아야 재사용 — 아니면 죽은 통로로 계속 실패함
        for (id, ch) in result { if let old = cache[id], old.entryID == ch.entryID { result[id] = old } }
        cache = result
        return result
    }

    private static func prop(_ e: io_registry_entry_t, _ key: String) -> Any? {
        IORegistryEntryCreateCFProperty(e, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
    }
}

final class DDCChannel {
    let displayID: CGDirectDisplayID
    let entryID: UInt64
    private let service: CFTypeRef
    /// 쓰기 직후 모니터가 약 1초 동안 엉뚱한 응답을 돌려주므로 그동안 읽지 않음
    private var readReadyAt: CFAbsoluteTime = 0
    /// 연속 쓰기 최소 간격 — 실측: 0.25초 간격이면 두 번째 쓰기가 무시되고 0.5초부터 적용됨
    private var writeReadyAt: CFAbsoluteTime = 0
    private static let chip: UInt32 = 0x37, addr: UInt32 = 0x51

    init(displayID: CGDirectDisplayID, service: CFTypeRef, entryID: UInt64) {
        self.displayID = displayID
        self.service = service
        self.entryID = entryID
    }

    /// VCP 값 읽기. 응답 체크섬까지 맞아야 인정한다.
    func read(_ code: UInt8, attempts: Int = 4) -> (value: Int, max: Int)? {
        guard let rd = DDC.readFn else { return nil }
        waitUntil(readReadyAt)
        for _ in 0..<attempts {
            guard send([0x01, code]) else { usleep(40_000); continue }
            usleep(50_000)
            var r = [UInt8](repeating: 0, count: 12)
            guard rd(service, Self.chip, Self.addr, &r, UInt32(r.count)) == kIOReturnSuccess else { usleep(40_000); continue }
            // [0x6E, 0x88, 0x02(VCP 응답), 결과(0=지원), VCP, 형식, 최대H, 최대L, 현재H, 현재L, 체크섬]
            let chk = r[0..<10].reduce(UInt8(0x50)) { $0 ^ $1 }
            if r[0] == 0x6E, r[1] == 0x88, r[2] == 0x02, r[3] == 0x00, r[4] == code, r[10] == chk {
                return (Int(r[8]) << 8 | Int(r[9]), Int(r[6]) << 8 | Int(r[7]))
            }
            usleep(60_000)
        }
        return nil
    }

    @discardableResult
    func write(_ code: UInt8, _ value: Int) -> Bool {
        waitUntil(writeReadyAt)
        let ok = send([0x03, code, UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)])
        let now = CFAbsoluteTimeGetCurrent()
        readReadyAt = now + 1.5
        writeReadyAt = now + 0.6
        return ok
    }

    private func send(_ body: [UInt8]) -> Bool {
        guard let wr = DDC.writeFn else { return false }
        var p: [UInt8] = [0x80 | UInt8(body.count)] + body
        p.append(p.reduce(UInt8(0x6E ^ 0x51)) { $0 ^ $1 })
        return wr(service, Self.chip, Self.addr, &p, UInt32(p.count)) == kIOReturnSuccess
    }

    private func waitUntil(_ t: CFAbsoluteTime) {
        let wait = t - CFAbsoluteTimeGetCurrent()
        if wait > 0 { usleep(useconds_t(wait * 1_000_000)) }
    }
}
