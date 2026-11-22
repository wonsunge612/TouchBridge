import CoreGraphics
import Foundation
import IOKit
import IOKit.hid

extension Notification.Name {
    static let touchDevicesDidChange = Notification.Name("TouchBridge.touchDevicesDidChange")
}

/// 한 리포트(프레임) 시점에 패널 위에 닿아 있는 모든 접점.
struct TouchFrame {
    struct Contact {
        let id: Int
        /// 패널 정규화 좌표 0…1 (좌상단 원점)
        let point: CGPoint
    }
    let panelKey: String
    /// id 오름차순. 비어 있으면 모든 손가락이 떨어진 상태.
    let contacts: [Contact]
}

enum HIDRole { case digitizer, pointer }

/// 장치의 리포트 디스크립터에서 미리 뽑아 둔 요소 배치.
/// 값 콜백은 "바뀐 값"만 오기 때문에, 리포트가 올 때마다 슬롯 전체를 직접 읽는다.
struct DeviceLayout {
    struct Slot {
        var order: IOHIDElementCookie = 0
        var reportID: UInt32 = 0
        var tip: IOHIDElement?
        var contactID: IOHIDElement?
        var x: IOHIDElement?
        var y: IOHIDElement?
    }

    struct Pointer {
        var reportID: UInt32 = 0
        var x: IOHIDElement?
        var y: IOHIDElement?
        var button: IOHIDElement?
    }

    var slots: [UInt32: [Slot]] = [:]            // reportID → finger 슬롯들 (순서대로)
    var contactCount: [UInt32: IOHIDElement] = [:]
    var pointers: [UInt32: [Pointer]] = [:]
    var maxContacts = 0

    static func build(_ dev: IOHIDDevice) -> DeviceLayout {
        var layout = DeviceLayout()
        let elems = (IOHIDDeviceCopyMatchingElements(dev, nil, IOOptionBits(kIOHIDOptionsTypeNone)) as? [IOHIDElement]) ?? []
        var slotMap: [IOHIDElementCookie: Slot] = [:]
        var ptrMap: [IOHIDElementCookie: Pointer] = [:]
        let inputTypes: Set<UInt32> = [kIOHIDElementTypeInput_Misc.rawValue,
                                      kIOHIDElementTypeInput_Button.rawValue,
                                      kIOHIDElementTypeInput_Axis.rawValue]

        for e in elems where inputTypes.contains(IOHIDElementGetType(e).rawValue) {
            let page = IOHIDElementGetUsagePage(e), usage = IOHIDElementGetUsage(e)
            guard let app = HIDUtil.applicationCollection(of: e) else { continue }
            let appPage = IOHIDElementGetUsagePage(app)
            let rid = IOHIDElementGetReportID(e)
            let isX = page == HIDUtil.pageGD && usage == UInt32(kHIDUsage_GD_X) && !IOHIDElementIsRelative(e)
            let isY = page == HIDUtil.pageGD && usage == UInt32(kHIDUsage_GD_Y) && !IOHIDElementIsRelative(e)
            let isTip = page == HIDUtil.pageDig && usage == UInt32(kHIDUsage_Dig_TipSwitch)
            let isButton1 = page == HIDUtil.pageButton && usage == 1

            if appPage == HIDUtil.pageDig {
                if page == HIDUtil.pageDig && usage == UInt32(kHIDUsage_Dig_ContactCount) {
                    layout.contactCount[rid] = e
                    continue
                }
                let key = HIDUtil.contactCollection(of: e)
                var s = slotMap[key] ?? Slot(order: key)
                if isX { s.x = e; s.reportID = rid }
                if isY { s.y = e }
                if isTip || (isButton1 && s.tip == nil) { s.tip = e }
                if page == HIDUtil.pageDig && usage == UInt32(kHIDUsage_Dig_ContactIdentifier) { s.contactID = e }
                slotMap[key] = s
            } else if appPage == HIDUtil.pageGD {
                let key = IOHIDElementGetCookie(app)
                var p = ptrMap[key] ?? Pointer()
                if isX { p.x = e; p.reportID = rid }
                if isY { p.y = e }
                if isButton1 || isTip { p.button = p.button ?? e }
                ptrMap[key] = p
            }
        }
        for s in slotMap.values.sorted(by: { $0.order < $1.order }) where s.x != nil && s.y != nil {
            layout.slots[s.reportID, default: []].append(s)
            layout.maxContacts += 1
        }
        for p in ptrMap.values where p.x != nil && p.y != nil {
            layout.pointers[p.reportID, default: []].append(p)
        }
        return layout
    }
}

final class OpenedDevice {
    let device: IOHIDDevice
    let role: HIDRole
    let seized: Bool
    let layout: DeviceLayout
    let buffer: UnsafeMutablePointer<UInt8>
    let bufferSize: Int

    init(device: IOHIDDevice, role: HIDRole, seized: Bool, layout: DeviceLayout, bufferSize: Int) {
        self.device = device
        self.role = role
        self.seized = seized
        self.layout = layout
        self.bufferSize = bufferSize
        buffer = .allocate(capacity: bufferSize)
    }

    deinit { buffer.deallocate() }
}

/// 하나의 물리 터치 패널. 대부분의 터치 모니터는 같은 USB 장치 안에
/// Digitizer(Touch Screen) 인터페이스 + 절대좌표 Mouse 인터페이스를 함께 노출한다.
final class TouchPanel {
    let key: String
    let name: String
    var devices: [OpenedDevice] = []
    var active: [Int: (point: CGPoint, seen: CFAbsoluteTime)] = [:]
    var lastDigitizerFrame: CFAbsoluteTime = 0
    /// 진단: 마지막으로 좌표를 공급한 경로
    var lastSource: HIDRole?
    var seenReports = Set<String>()

    init(key: String, name: String) {
        self.key = key
        self.name = name
    }

    var allSeized: Bool { devices.allSatisfy(\.seized) }
    var maxContacts: Int { devices.map(\.layout.maxContacts).max() ?? 0 }
}

/// IOHIDManager로 Vendor ID와 무관하게 HID Digitizer / Touch Screen(0x0D / 0x04)을
/// 감지하고, 같은 물리 장치의 절대좌표 포인터 인터페이스까지 묶어서 독점(seize)한다.
final class TouchDeviceManager {
    var onFrame: ((TouchFrame) -> Void)?
    /// 터치 장치에서 리포트가 들어올 때마다 호출 (호환 모드 이벤트 억제 타이밍용)
    var onActivity: (() -> Void)?

    private var digitizerManager: IOHIDManager?
    private var pointerManager: IOHIDManager?
    private(set) var panels: [String: TouchPanel] = [:]
    private var deviceToPanel: [IOHIDDevice: String] = [:]
    /// 같은 IOService가 매니저마다 다른 IOHIDDevice 객체로 올 수 있어 레지스트리 ID로 중복 방지
    private var openedServices: [UInt64: IOHIDDevice] = [:]
    private(set) var isRunning = false

    /// 하나라도 독점에 실패하면 macOS도 같은 입력을 받으므로 EventTap 억제가 필요
    var needsSuppression: Bool { panels.values.contains { !$0.allSeized } }

    // MARK: Lifecycle

    func start() {
        guard !isRunning else { return }
        isRunning = true
        let ctx = Unmanaged.passUnretained(self).toOpaque()

        let dm = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerSetDeviceMatching(dm, [
            kIOHIDDeviceUsagePageKey: kHIDPage_Digitizer,
            kIOHIDDeviceUsageKey: kHIDUsage_Dig_TouchScreen,
        ] as CFDictionary)
        IOHIDManagerRegisterDeviceMatchingCallback(dm, { ctx, _, _, dev in
            guard let ctx else { return }
            Unmanaged<TouchDeviceManager>.fromOpaque(ctx).takeUnretainedValue().digitizerMatched(dev)
        }, ctx)
        IOHIDManagerRegisterDeviceRemovalCallback(dm, { ctx, _, _, dev in
            guard let ctx else { return }
            Unmanaged<TouchDeviceManager>.fromOpaque(ctx).takeUnretainedValue().deviceRemoved(dev)
        }, ctx)
        IOHIDManagerScheduleWithRunLoop(dm, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        IOHIDManagerOpen(dm, IOOptionBits(kIOHIDOptionsTypeNone))
        digitizerManager = dm

        // 같은 물리 장치에 속한 절대좌표 Mouse/Pointer 인터페이스 탐색용
        let pm = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerSetDeviceMatchingMultiple(pm, [
            [kIOHIDDeviceUsagePageKey: kHIDPage_GenericDesktop, kIOHIDDeviceUsageKey: kHIDUsage_GD_Mouse],
            [kIOHIDDeviceUsagePageKey: kHIDPage_GenericDesktop, kIOHIDDeviceUsageKey: kHIDUsage_GD_Pointer],
        ] as CFArray)
        IOHIDManagerRegisterDeviceMatchingCallback(pm, { ctx, _, _, dev in
            guard let ctx else { return }
            Unmanaged<TouchDeviceManager>.fromOpaque(ctx).takeUnretainedValue().pointerMatched(dev)
        }, ctx)
        IOHIDManagerRegisterDeviceRemovalCallback(pm, { ctx, _, _, dev in
            guard let ctx else { return }
            Unmanaged<TouchDeviceManager>.fromOpaque(ctx).takeUnretainedValue().deviceRemoved(dev)
        }, ctx)
        IOHIDManagerScheduleWithRunLoop(pm, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        IOHIDManagerOpen(pm, IOOptionBits(kIOHIDOptionsTypeNone))
        pointerManager = pm
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        for panel in panels.values {
            releaseTouch(panel)
            panel.devices.forEach(close)
        }
        panels.removeAll()
        deviceToPanel.removeAll()
        openedServices.removeAll()
        for m in [digitizerManager, pointerManager].compactMap({ $0 }) {
            IOHIDManagerUnscheduleFromRunLoop(m, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
            IOHIDManagerClose(m, IOOptionBits(kIOHIDOptionsTypeNone))
        }
        digitizerManager = nil
        pointerManager = nil
        postChange()
    }

    // MARK: Matching

    private func digitizerMatched(_ dev: IOHIDDevice) {
        guard deviceToPanel[dev] == nil, openedServices[HIDUtil.serviceID(dev)] == nil else { return }
        let key = HIDUtil.physicalKey(dev)
        let panel = panels[key] ?? TouchPanel(key: key, name: HIDUtil.displayName(dev))
        panels[key] = panel
        open(dev, role: .digitizer, into: panel)

        // 먼저 매칭되어 있던 형제 포인터 인터페이스 붙이기
        if let pm = pointerManager, let devs = IOHIDManagerCopyDevices(pm) as? Set<IOHIDDevice> {
            devs.forEach(pointerMatched)
        }
    }

    private func pointerMatched(_ dev: IOHIDDevice) {
        guard deviceToPanel[dev] == nil, openedServices[HIDUtil.serviceID(dev)] == nil,
              let panel = panels[HIDUtil.physicalKey(dev)],
              HIDUtil.hasAbsoluteXY(dev) // 상대좌표(일반 마우스)는 절대 건드리지 않음
        else { return }
        open(dev, role: .pointer, into: panel)
    }

    private func deviceRemoved(_ dev: IOHIDDevice) {
        let sid = HIDUtil.serviceID(dev)
        let dev = openedServices[sid] ?? dev
        openedServices[sid] = nil
        guard let key = deviceToPanel.removeValue(forKey: dev), let panel = panels[key] else { return }
        if let d = panel.devices.first(where: { $0.device == dev }) { close(d) }
        panel.devices.removeAll { $0.device == dev }
        Diag.log("장치 분리: \(HIDUtil.displayName(dev))")
        // 디지타이저 인터페이스가 모두 사라지면 패널 전체 해제
        if !panel.devices.contains(where: { $0.role == .digitizer }) {
            releaseTouch(panel)
            for d in panel.devices {
                close(d)
                deviceToPanel[d.device] = nil
                openedServices[HIDUtil.serviceID(d.device)] = nil
            }
            panels[key] = nil
        }
        postChange()
    }

    private func open(_ dev: IOHIDDevice, role: HIDRole, into panel: TouchPanel) {
        // 1순위: 독점(seize) — macOS가 이 장치로 커서를 움직이지 못하게 한다.
        var seized = true
        var r = IOHIDDeviceOpen(dev, IOOptionBits(kIOHIDOptionsTypeSeizeDevice))
        if r != kIOReturnSuccess {
            seized = false
            r = IOHIDDeviceOpen(dev, IOOptionBits(kIOHIDOptionsTypeNone))
        }
        guard r == kIOReturnSuccess else {
            Diag.log(String(format: "장치 열기 실패 0x%08X %@ (%@) — 입력 모니터링 권한 확인 필요",
                            r, HIDUtil.displayName(dev), role == .digitizer ? "digitizer" : "pointer"))
            return
        }
        let size = max(HIDUtil.prop(dev, kIOHIDMaxInputReportSizeKey) ?? 64, 64)
        let od = OpenedDevice(device: dev, role: role, seized: seized, layout: .build(dev), bufferSize: size)
        IOHIDDeviceRegisterInputReportCallback(dev, od.buffer, size, { ctx, _, sender, _, reportID, _, _ in
            guard let ctx, let sender else { return }
            let dev = Unmanaged<IOHIDDevice>.fromOpaque(sender).takeUnretainedValue()
            Unmanaged<TouchDeviceManager>.fromOpaque(ctx).takeUnretainedValue().handleReport(dev, reportID)
        }, Unmanaged.passUnretained(self).toOpaque())
        IOHIDDeviceScheduleWithRunLoop(dev, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        panel.devices.append(od)
        deviceToPanel[dev] = panel.key
        openedServices[HIDUtil.serviceID(dev)] = dev
        Diag.log(String(format: "장치 연결: %@ [%@] %@, 접점 %d개", HIDUtil.displayName(dev),
                        role == .digitizer ? "digitizer" : "pointer",
                        seized ? "독점(seize) 성공" : "독점 실패 → 공유 모드", od.layout.maxContacts))
        if role == .digitizer { wakeMultitouch(dev) }
        postChange()
    }

    /// Windows는 열거 시점에 Contact Count Maximum / 인증 blob 등 디지타이저 Feature 리포트를 읽는다.
    /// 일부 컨트롤러는 이 요청을 받아야 단일 터치(마우스) 모드에서 멀티터치 리포트로 전환한다.
    private func wakeMultitouch(_ dev: IOHIDDevice) {
        let match = [kIOHIDElementTypeKey: kIOHIDElementTypeFeature.rawValue] as CFDictionary
        let feats = (IOHIDDeviceCopyMatchingElements(dev, match, IOOptionBits(kIOHIDOptionsTypeNone)) as? [IOHIDElement]) ?? []
        let rids = Set(feats.map { IOHIDElementGetReportID($0) }).sorted()
        let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: 1024)
        defer { buf.deallocate() }
        for rid in rids {
            var len = CFIndex(1024)
            let r = IOHIDDeviceGetReport(dev, kIOHIDReportTypeFeature, CFIndex(rid), buf, &len)
            let head = (0..<min(Int(len), 4)).map { String(format: "%02X", buf[$0]) }.joined(separator: " ")
            Diag.log(String(format: "Feature 리포트 읽기 rid %d → 0x%08X (%d bytes: %@…)", rid, r, len, head))
        }
    }

    private func close(_ d: OpenedDevice) {
        IOHIDDeviceRegisterInputReportCallback(d.device, d.buffer, d.bufferSize, nil, nil)
        IOHIDDeviceUnscheduleFromRunLoop(d.device, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        IOHIDDeviceClose(d.device, IOOptionBits(d.seized ? kIOHIDOptionsTypeSeizeDevice : kIOHIDOptionsTypeNone))
    }

    private func postChange() {
        NotificationCenter.default.post(name: .touchDevicesDidChange, object: self)
    }

    // MARK: Report → frame

    private func handleReport(_ dev: IOHIDDevice, _ reportID: UInt32) {
        guard let key = deviceToPanel[dev], let panel = panels[key],
              let od = panel.devices.first(where: { $0.device == dev }) else { return }
        onActivity?()
        let now = CFAbsoluteTimeGetCurrent()
        let tag = "\(od.role == .digitizer ? "digitizer" : "pointer") rid \(reportID)"
        if panel.seenReports.insert(tag).inserted { Diag.log("첫 리포트 수신: \(tag)") }

        if let slots = od.layout.slots[reportID] {
            // Parallel 모드: Contact Count 개수만큼의 앞쪽 슬롯만 유효.
            // Hybrid 모드의 후속 리포트는 Contact Count가 0 → 리포트 안의 슬롯 전부 사용.
            var valid = slots[...]
            if let cc = od.layout.contactCount[reportID], let n = HIDUtil.intValue(dev, cc), n > 0, n < slots.count {
                valid = slots.prefix(n)
            }
            var downs: [Int: CGPoint] = [:]
            var ups = Set<Int>()
            for (i, s) in valid.enumerated() {
                guard let xe = s.x, let ye = s.y else { continue }
                let id = s.contactID.flatMap { HIDUtil.intValue(dev, $0) } ?? i
                let tip = s.tip.flatMap { HIDUtil.intValue(dev, $0) }.map { $0 != 0 } ?? true
                if tip, let x = HIDUtil.intValue(dev, xe), let y = HIDUtil.intValue(dev, ye) {
                    downs[id] = CGPoint(x: HIDUtil.normalize(x, xe), y: HIDUtil.normalize(y, ye))
                } else {
                    ups.insert(id)
                }
            }
            for id in ups where downs[id] == nil { panel.active[id] = nil }
            for (id, p) in downs { panel.active[id] = (p, now) }
            // 해제 리포트를 놓친 접점 정리
            panel.active = panel.active.filter { now - $0.value.seen < 0.5 }
            panel.lastDigitizerFrame = now
            if panel.lastSource != .digitizer {
                panel.lastSource = .digitizer
                Diag.log("좌표 경로: 디지타이저 (멀티터치)")
            }
            emit(panel)
        }

        // 디지타이저가 조용할 때만 절대좌표 포인터 인터페이스 사용 (단일 터치)
        if let ptr = od.layout.pointers[reportID]?.first, now - panel.lastDigitizerFrame > 0.3,
           let xe = ptr.x, let ye = ptr.y, let x = HIDUtil.intValue(dev, xe), let y = HIDUtil.intValue(dev, ye) {
            let pressed = ptr.button.flatMap { HIDUtil.intValue(dev, $0) }.map { $0 != 0 } ?? false
            panel.active = pressed
                ? [0: (CGPoint(x: HIDUtil.normalize(x, xe), y: HIDUtil.normalize(y, ye)), now)]
                : [:]
            if panel.lastSource != .pointer {
                panel.lastSource = .pointer
                Diag.log("좌표 경로: 마우스 인터페이스 (단일 터치) — 패널이 멀티터치 리포트를 보내지 않음")
            }
            emit(panel)
        }
    }

    private func emit(_ panel: TouchPanel) {
        let contacts = panel.active.keys.sorted().map { TouchFrame.Contact(id: $0, point: panel.active[$0]!.point) }
        onFrame?(TouchFrame(panelKey: panel.key, contacts: contacts))
    }

    private func releaseTouch(_ panel: TouchPanel) {
        guard !panel.active.isEmpty else { return }
        panel.active.removeAll()
        emit(panel)
    }
}

enum HIDUtil {
    static let pageGD = UInt32(kHIDPage_GenericDesktop)
    static let pageDig = UInt32(kHIDPage_Digitizer)
    static let pageButton = UInt32(kHIDPage_Button)

    static func prop<T>(_ d: IOHIDDevice, _ k: String) -> T? {
        IOHIDDeviceGetProperty(d, k as CFString) as? T
    }

    /// 입력 요소의 최신 값 (입력 요소는 장치 I/O 없이 마지막 리포트 값을 돌려준다)
    static func intValue(_ d: IOHIDDevice, _ e: IOHIDElement) -> Int? {
        var u = Unmanaged.passUnretained(placeholder(e))
        guard IOHIDDeviceGetValue(d, e, &u) == kIOReturnSuccess else { return nil }
        return IOHIDValueGetIntegerValue(u.takeUnretainedValue())
    }

    private static var placeholderValue: IOHIDValue?
    private static func placeholder(_ e: IOHIDElement) -> IOHIDValue {
        if let v = placeholderValue { return v }
        let v = IOHIDValueCreateWithIntegerValue(kCFAllocatorDefault, e, 0, 0)
        placeholderValue = v
        return v
    }

    static func serviceID(_ d: IOHIDDevice) -> UInt64 {
        var id: UInt64 = 0
        IORegistryEntryGetRegistryEntryID(IOHIDDeviceGetService(d), &id)
        return id
    }

    static func displayName(_ d: IOHIDDevice) -> String {
        let product: String = prop(d, kIOHIDProductKey) ?? "Touch Screen"
        let vid: Int = prop(d, kIOHIDVendorIDKey) ?? 0
        let pid: Int = prop(d, kIOHIDProductIDKey) ?? 0
        return String(format: "%@ (%04X:%04X)", product, vid, pid)
    }

    /// 같은 물리 장치의 인터페이스들이 공유하는 키 (VID/PID/LocationID/Serial)
    static func physicalKey(_ d: IOHIDDevice) -> String {
        let vid: Int = prop(d, kIOHIDVendorIDKey) ?? 0
        let pid: Int = prop(d, kIOHIDProductIDKey) ?? 0
        let loc: Int = prop(d, kIOHIDLocationIDKey) ?? 0
        let serial: String = prop(d, kIOHIDSerialNumberKey) ?? ""
        return String(format: "%04X:%04X:%08X:", vid, pid, loc) + serial
    }

    static func hasAbsoluteXY(_ d: IOHIDDevice) -> Bool {
        let match = [kIOHIDElementUsagePageKey: kHIDPage_GenericDesktop,
                     kIOHIDElementUsageKey: kHIDUsage_GD_X] as CFDictionary
        guard let elems = IOHIDDeviceCopyMatchingElements(d, match, IOOptionBits(kIOHIDOptionsTypeNone))
                as? [IOHIDElement] else { return false }
        return elems.contains { !IOHIDElementIsRelative($0) }
    }

    static func normalize(_ v: Int, _ e: IOHIDElement) -> Double {
        let mn = IOHIDElementGetLogicalMin(e), mx = IOHIDElementGetLogicalMax(e)
        guard mx > mn else { return 0 }
        return min(max(Double(v - mn) / Double(mx - mn), 0), 1)
    }

    static func applicationCollection(of e: IOHIDElement) -> IOHIDElement? {
        var cur = IOHIDElementGetParent(e)
        var app: IOHIDElement?
        while let c = cur {
            if IOHIDElementGetCollectionType(c) == kIOHIDElementCollectionTypeApplication { app = c }
            cur = IOHIDElementGetParent(c)
        }
        return app
    }

    /// 값이 속한 Finger/Stylus/Puck 논리 컬렉션 (멀티터치 슬롯 구분용)
    static func contactCollection(of e: IOHIDElement) -> IOHIDElementCookie {
        let contactUsages: Set<UInt32> = [UInt32(kHIDUsage_Dig_Finger), UInt32(kHIDUsage_Dig_Stylus), UInt32(kHIDUsage_Dig_Puck)]
        var cur = IOHIDElementGetParent(e)
        var fallback: IOHIDElementCookie = 0
        while let c = cur {
            if IOHIDElementGetUsagePage(c) == pageDig && contactUsages.contains(IOHIDElementGetUsage(c)) {
                return IOHIDElementGetCookie(c)
            }
            if IOHIDElementGetCollectionType(c) == kIOHIDElementCollectionTypeApplication {
                fallback = IOHIDElementGetCookie(c)
            }
            cur = IOHIDElementGetParent(c)
        }
        return fallback
    }
}
