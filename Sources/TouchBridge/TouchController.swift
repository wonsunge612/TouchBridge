import AppKit
import ApplicationServices
import IOKit.hid

/// 장치 → 좌표 매핑 → 이벤트 합성을 연결하는 중심 객체.
final class TouchController {
    let devices = TouchDeviceManager()
    let displays = DisplayManager.shared
    let injector = EventInjector()
    lazy var gestures = GestureEngine(injector: injector)
    let settings = AppSettings.shared
    /// 여러 패널이 동시에 쓰일 때 먼저 닿은 패널이 제스처를 소유
    private var activePanel: String?

    /// 보정 중에는 원시 패널 좌표를 이 sink로 보내고 이벤트는 합성하지 않는다.
    private var calibrationSink: ((CGPoint, Bool) -> Void)?
    private var permissionTimer: Timer?
    private var lastListenGranted = false

    var enabled: Bool {
        get { settings.touchEnabled }
        set {
            settings.touchEnabled = newValue
            applyRunState()
        }
    }

    init() {
        devices.onFrame = { [weak self] in self?.handle($0) }
        devices.onActivity = { [weak self] in self?.injector.noteTouchActivity() }
        injector.touchBusy = { [weak self] in self?.gestures.isActive ?? false }
        gestures.tuning.pinchGain = settings.pinchGain
        NotificationCenter.default.addObserver(forName: .touchDevicesDidChange, object: nil, queue: .main) {
            [weak self] _ in self?.updateSuppression()
        }
        NotificationCenter.default.addObserver(forName: .displaysDidChange, object: nil, queue: .main) {
            [weak self] _ in self?.logTargetChange()
        }
    }

    func start() {
        Diag.log("TouchBridge 시작 — 권한: 입력 모니터링=\(Permissions.inputMonitoring) 손쉬운 사용=\(Permissions.accessibility) 이벤트 전송=\(Permissions.postEvents)")
        for d in displays.displays {
            Diag.log("디스플레이 \(d.id) \(d.name) bounds=\(d.bounds) main=\(d.isMain) key=\(d.key)")
        }
        Diag.log("터치 기능=\(enabled)")
        logTargetChange()
        Permissions.requestAll()
        lastListenGranted = Permissions.inputMonitoring
        applyRunState()
        // 권한이 나중에 허용되면 HID를 다시 열어야 장치가 보인다.
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            guard let self else { return }
            let granted = Permissions.inputMonitoring
            if granted != self.lastListenGranted {
                self.lastListenGranted = granted
                Diag.log("입력 모니터링 권한 변경 → \(granted), 장치 다시 열기")
                self.restartDevices()
            }
            self.updateSuppression()
        }
    }

    func shutdown() {
        gestures.reset()
        devices.stop()
        injector.setSuppression(false)
    }

    private var shouldRun: Bool { enabled || calibrationSink != nil }

    private func applyRunState() {
        if shouldRun { devices.start() } else { devices.stop(); gestures.reset() }
        updateSuppression()
    }

    private func restartDevices() {
        devices.stop()
        applyRunState()
    }

    private func updateSuppression() {
        let want = devices.isRunning && devices.needsSuppression
        let was = injector.suppressionActive
        let ok = injector.setSuppression(want)
        if want != was || !ok {
            Diag.log("호환 모드 이벤트 필터: 필요=\(want) 적용=\(injector.suppressionActive)\(ok ? "" : " (손쉬운 사용 권한 없음)")")
        }
    }

    private var lastContactCount = 0
    private var touching = false

    var pinchGain: Double {
        get { settings.pinchGain }
        set { settings.pinchGain = newValue; gestures.tuning.pinchGain = newValue }
    }

    // MARK: Target display

    var targetDisplay: DisplayInfo? {
        // 고른 모니터가 아직 연결되지 않았으면(예: 터치 USB가 화면보다 먼저 연결됨) 다른 화면으로 보내지 않고 무시
        if let key = settings.targetDisplayKey { return displays.display(forKey: key) }
        return displays.defaultTarget
    }

    private var lastLoggedTarget: String??

    private func logTargetChange() {
        let t = targetDisplay
        let desc = t.map { "\($0.name) \($0.bounds)" }
        guard lastLoggedTarget != .some(desc) else { return }
        lastLoggedTarget = .some(desc)
        Diag.log("대상 모니터 → \(desc ?? "연결 안 됨 (터치 무시)")")
        if t == nil { gestures.reset() }
    }

    func selectTarget(_ d: DisplayInfo) {
        gestures.reset()
        settings.targetDisplayKey = d.key
        logTargetChange()
    }

    // MARK: Mapping

    private func handle(_ f: TouchFrame) {
        if let owner = activePanel, owner != f.panelKey { return }
        activePanel = f.contacts.isEmpty ? nil : f.panelKey

        if let sink = calibrationSink {
            // 보정은 첫 번째 접점의 원시 패널 좌표만 사용
            sink(f.contacts.first?.point ?? .zero, !f.contacts.isEmpty)
            return
        }
        guard enabled, let target = targetDisplay else { return }

        let cal = settings.calibration(for: target.calibrationKey) ?? .identity
        // 이벤트마다 현재 디스플레이 영역을 다시 읽어 배치/해상도 변경을 즉시 반영
        var b = CGDisplayBounds(target.id)
        if b.isEmpty { b = target.bounds }
        let mapped = f.contacts.map { c -> (id: Int, point: CGPoint) in
            let n = cal.apply(c.point)
            let nx = min(max(n.x, 0), 1), ny = min(max(n.y, 0), 1)
            return (c.id, CGPoint(x: b.minX + nx * max(b.width - 1, 0),
                                  y: b.minY + ny * max(b.height - 1, 0)))
        }
        // 터치가 시작될 때: 손가락 아래 창이 키 창이 아니면 먼저 활성화 (첫 동작이 활성화에만 쓰이지 않게)
        if !touching, let first = mapped.first, !gestures.isActive {
            if let r = WindowFocus.focus(at: first.point) {
                injector.holdUntilActive(pid: r.pid, raisedOnly: r.raisedOnly)
                Diag.log("터치한 창 활성화: \(r.appName)\(r.raisedOnly ? " (같은 앱 다른 창)" : "")")
            }
        }
        touching = !f.contacts.isEmpty
        if f.contacts.count != lastContactCount {
            lastContactCount = f.contacts.count
            let raw = f.contacts.map { Diag.fmtN($0.point) }.joined(separator: " ")
            let scr = mapped.map { Diag.fmt($0.point) }.joined(separator: " ")
            Diag.log("접점 \(f.contacts.count)개 raw \(raw) → \(target.name) \(scr)")
        }
        gestures.process(mapped)
    }

    // MARK: Calibration

    func beginCalibration(sink: @escaping (CGPoint, Bool) -> Void) {
        gestures.reset()
        calibrationSink = sink
        applyRunState()
    }

    func endCalibration() {
        calibrationSink = nil
        applyRunState()
    }

    func resetCalibration() {
        guard let t = targetDisplay else { return }
        settings.setCalibration(nil, for: t.calibrationKey)
    }

    var isTargetCalibrated: Bool {
        guard let t = targetDisplay else { return false }
        return settings.calibration(for: t.calibrationKey) != nil
    }
}

enum Permissions {
    static var inputMonitoring: Bool { IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted }
    static var accessibility: Bool { AXIsProcessTrusted() }
    static var postEvents: Bool { CGPreflightPostEventAccess() }

    static func requestAll() {
        if !inputMonitoring { _ = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent) }
        if !postEvents { _ = CGRequestPostEventAccess() }
        if !accessibility {
            let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
            _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
        }
    }

    static func openSettings(_ anchor: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") {
            NSWorkspace.shared.open(url)
        }
    }
}
