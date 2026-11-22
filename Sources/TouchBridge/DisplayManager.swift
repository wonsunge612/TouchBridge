import AppKit
import CoreGraphics

extension Notification.Name {
    static let displaysDidChange = Notification.Name("TouchBridge.displaysDidChange")
}

struct DisplayInfo: Equatable {
    let id: CGDirectDisplayID
    /// 재부팅/재연결 후에도 유지되는 식별자 (vendor-model-serial)
    let key: String
    let name: String
    /// 전역 좌표계(주 모니터 좌상단 원점, 포인트 단위) — CGEvent가 쓰는 좌표계
    let bounds: CGRect
    let isMain: Bool
    let isBuiltin: Bool
    let rotation: Int

    /// 회전 상태별로 보정값을 따로 저장한다.
    var calibrationKey: String { "\(key)@\(rotation)" }
}

/// NSScreen / CGDisplay 목록을 관리하고 배치·해상도·회전 변경을 실시간 반영한다.
final class DisplayManager {
    static let shared = DisplayManager()

    private(set) var displays: [DisplayInfo] = []
    private var refreshScheduled = false

    private init() {
        refresh()
        // 1) Quartz 재구성 콜백: 배치 이동, 해상도, 미러링, 회전, 연결/해제
        CGDisplayRegisterReconfigurationCallback({ _, flags, ctx in
            guard !flags.contains(.beginConfigurationFlag), let ctx else { return }
            Unmanaged<DisplayManager>.fromOpaque(ctx).takeUnretainedValue().scheduleRefresh()
        }, Unmanaged.passUnretained(self).toOpaque())
        // 2) AppKit 알림 (NSScreen 갱신 이후 시점)
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.scheduleRefresh() }
    }

    private func scheduleRefresh() {
        guard !refreshScheduled else { return }
        refreshScheduled = true
        DispatchQueue.main.async { [weak self] in
            self?.refreshScheduled = false
            self?.refresh()
        }
    }

    func refresh() {
        var count: UInt32 = 0
        CGGetActiveDisplayList(0, nil, &count)
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetActiveDisplayList(count, &ids, &count)

        let new = ids.prefix(Int(count)).map { id in
            DisplayInfo(
                id: id,
                key: Self.stableKey(id),
                name: Self.screen(for: id)?.localizedName ?? "Display \(id)",
                bounds: CGDisplayBounds(id),
                isMain: CGDisplayIsMain(id) != 0,
                isBuiltin: CGDisplayIsBuiltin(id) != 0,
                rotation: Int(CGDisplayRotation(id).rounded())
            )
        }
        .sorted { ($0.bounds.minX, $0.bounds.minY) < ($1.bounds.minX, $1.bounds.minY) }

        if new != displays {
            displays = new
            NotificationCenter.default.post(name: .displaysDidChange, object: self)
        }
    }

    func display(forKey key: String) -> DisplayInfo? { displays.first { $0.key == key } }

    /// 저장된 선택이 없을 때: 외장 보조 모니터 → 외장 모니터.
    /// 터치 패널은 항상 외장 모니터에 달려 있으므로 내장 디스플레이는 자동 선택하지 않는다.
    var defaultTarget: DisplayInfo? {
        displays.first { !$0.isBuiltin && !$0.isMain } ?? displays.first { !$0.isBuiltin }
    }

    static func screen(for id: CGDirectDisplayID) -> NSScreen? {
        NSScreen.screens.first {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == id
        }
    }

    static func stableKey(_ id: CGDirectDisplayID) -> String {
        let v = CGDisplayVendorNumber(id), m = CGDisplayModelNumber(id), s = CGDisplaySerialNumber(id)
        // 시리얼이 없는 동일 모델 모니터 2대를 구분하기 위해 unit 번호 추가
        return s != 0 ? "\(v)-\(m)-\(s)" : "\(v)-\(m)-u\(CGDisplayUnitNumber(id))"
    }
}
