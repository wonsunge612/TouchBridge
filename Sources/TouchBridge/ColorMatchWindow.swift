import AppKit
import AVFoundation
import SwiftUI

/// "맥북과 색 맞추기" 창: 준비(카메라 미리보기) → 측정 → 결과
final class ColorMatchModel: ObservableObject {
    enum Phase { case setup, running, done(ColorMatcher.Outcome), failed(String) }
    @Published var phase: Phase = .setup
    @Published var status = ""
    @Published var devices: [AVCaptureDevice] = []
    @Published var selected: String = "" { didSet { if selected != oldValue { startPreview() } } }
    @Published var effects: [String] = []
    @Published var permission = AVCaptureDevice.authorizationStatus(for: .video)
    @Published var reverted = false

    let displayName: String
    let camera = CameraSampler()
    private let displayID: CGDirectDisplayID
    private let displayKey: String
    private var matcher: ColorMatcher?
    private var patches: PatchWindows?
    private var effectsTimer: Timer?
    var onHideWindow: ((Bool) -> Void)?

    init(displayID: CGDirectDisplayID, displayKey: String, displayName: String) {
        self.displayID = displayID
        self.displayKey = displayKey
        self.displayName = displayName
    }

    func appear() {
        refreshDevices()
        if permission == .notDetermined {
            AVCaptureDevice.requestAccess(for: .video) { ok in
                DispatchQueue.main.async {
                    self.permission = ok ? .authorized : .denied
                    if ok { self.refreshDevices(); self.startPreview() }
                }
            }
        } else {
            startPreview()
        }
        effectsTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.effects = CameraSampler.activeVideoEffects()
        }
    }

    func disappear() {
        effectsTimer?.invalidate()
        matcher?.cancel()
        camera.stop()
    }

    func refreshDevices() {
        devices = CameraSampler.devices()
        if !devices.contains(where: { $0.uniqueID == selected }) { selected = devices.first?.uniqueID ?? "" }
    }

    private func startPreview() {
        guard permission == .authorized, let d = devices.first(where: { $0.uniqueID == selected }) else { return }
        do { try camera.start(d) } catch { status = "카메라를 열 수 없습니다: \(error.localizedDescription)" }
    }

    var canStart: Bool {
        permission == .authorized && !selected.isEmpty && camera.session.isRunning
    }

    func start() {
        guard let macScreen = NSScreen.screens.first(where: { CGDisplayIsBuiltin(Self.id(of: $0)) != 0 }),
              let extScreen = DisplayManager.screen(for: displayID) else {
            phase = .failed("맥북 화면과 외장 모니터가 모두 켜져 있어야 합니다.")
            return
        }
        let p = PatchWindows(macScreen: macScreen, extScreen: extScreen)
        let m = ColorMatcher(displayID: displayID, displayKey: displayKey, camera: camera, patches: p) { [weak self] event in
            guard let self else { return }
            switch event {
            case .status(let s): self.status = s
            case .finished(let o): self.phase = .done(o); self.onHideWindow?(false)
            case .failed(let msg): self.phase = .failed(msg); self.onHideWindow?(false)
            }
        }
        p.onCancel = { [weak m] in m?.cancel() }
        patches = p
        matcher = m
        phase = .running
        status = "준비 중…"
        onHideWindow?(true)
        m.start()
    }

    func revert(_ o: ColorMatcher.Outcome) {
        ColorMatcher.revert(displayID: displayID, displayKey: displayKey, to: o.originalGains) { [weak self] in
            self?.reverted = true
        }
    }

    func retry() {
        reverted = false
        phase = .setup
        status = ""
    }

    private static func id(of s: NSScreen) -> CGDirectDisplayID {
        (s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }
}

struct CameraPreview: NSViewRepresentable {
    let session: AVCaptureSession
    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspect
        v.layer = layer
        v.wantsLayer = true
        return v
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

struct ColorMatchView: View {
    @ObservedObject var model: ColorMatchModel
    var close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            switch model.phase {
            case .setup, .running: setup
            case .done(let o): result(o)
            case .failed(let msg): failure(msg)
            }
        }
        .padding(20)
        .frame(width: 520)
    }

    private var setup: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("\(model.displayName) 색을 맥북 화면에 맞추기").font(.title3.bold())
            Text("아이폰 카메라로 두 화면을 함께 찍어, 외장 모니터의 빨강·파랑 게인을 맥북과 같은 흰색이 되도록 조절합니다. 약 30초 걸리고, 그동안 두 화면이 회색으로 바뀝니다.")
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 4) {
                Label("아이폰을 잠그고 가로로 세워, 맥북과 외장 모니터가 함께 보이게 두세요", systemImage: "iphone")
                Label("평소 앉는 눈 위치 근처에 둘수록 결과가 눈에도 맞습니다", systemImage: "eye")
                Label("화면에 조명이 직접 비치지 않게 하세요", systemImage: "lightbulb.slash")
            }.font(.callout)

            if model.permission == .denied || model.permission == .restricted {
                Text("카메라 권한이 꺼져 있습니다. 시스템 설정 › 개인정보 보호 및 보안 › 카메라에서 TouchBridge를 켜 주세요.")
                    .foregroundColor(.red).fixedSize(horizontal: false, vertical: true)
            } else {
                Picker("카메라", selection: $model.selected) {
                    ForEach(model.devices, id: \.uniqueID) { Text($0.localizedName).tag($0.uniqueID) }
                }
                CameraPreview(session: model.camera.session)
                    .frame(height: 270)
                    .background(Color.black)
                    .cornerRadius(6)
            }
            if !model.effects.isEmpty {
                Text("⚠︎ 비디오 효과가 켜져 있습니다: \(model.effects.joined(separator: ", ")). 메뉴 막대의 초록색 카메라 아이콘에서 꺼 주세요.")
                    .foregroundColor(.orange).fixedSize(horizontal: false, vertical: true)
            }
            if !model.status.isEmpty { Text(model.status).foregroundColor(.secondary) }
            HStack {
                Button("새로고침") { model.refreshDevices() }
                Spacer()
                Button("닫기", action: close).keyboardShortcut(.cancelAction)
                Button("시작", action: model.start).keyboardShortcut(.defaultAction).disabled(!model.canStart)
            }
        }
    }

    private func result(_ o: ColorMatcher.Outcome) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(model.reverted ? "원래 색으로 되돌렸습니다" : "색 맞추기 완료").font(.title3.bold())
            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 6) {
                GridRow { Text(""); Text("전").bold(); Text("후").bold() }
                GridRow { Text("붉은 기 (맥북 대비)"); Text(pct(o.before.red)); Text(pct(o.after.red)) }
                GridRow { Text("푸른 기 (맥북 대비)"); Text(pct(o.before.blue)); Text(pct(o.after.blue)) }
                GridRow { Text("빨강 게인"); Text("\(o.originalGains[ColorMatcher.redGain] ?? 0)"); Text("\(o.finalGains[ColorMatcher.redGain] ?? 0)") }
                GridRow { Text("파랑 게인"); Text("\(o.originalGains[ColorMatcher.blueGain] ?? 0)"); Text("\(o.finalGains[ColorMatcher.blueGain] ?? 0)") }
            }.font(.body.monospacedDigit())
            Text("맞춘 색은 기억해 두었다가 모니터를 켤 때마다 다시 적용합니다. 카메라는 사람 눈과 색을 느끼는 방식이 조금 달라서, 눈으로 보기에 약간 다를 수 있습니다.")
                .font(.callout).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("다시 맞추기", action: model.retry)
                Spacer()
                if !model.reverted { Button("원래대로 되돌리기") { model.revert(o) } }
                Button("완료", action: close).keyboardShortcut(.defaultAction)
            }
        }
    }

    private func failure(_ msg: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("색 맞추기를 끝내지 못했습니다").font(.title3.bold())
            Text(msg).fixedSize(horizontal: false, vertical: true)
            Text("모니터 색은 원래대로 되돌려 두었습니다.").foregroundColor(.secondary)
            HStack {
                Spacer()
                Button("닫기", action: close)
                Button("다시 시도", action: model.retry).keyboardShortcut(.defaultAction)
            }
        }
    }

    private func pct(_ v: Double) -> String { String(format: "%+.1f%%", v * 100) }
}

final class ColorMatchWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private var model: ColorMatchModel?

    func show(displayID: CGDirectDisplayID, displayKey: String, displayName: String) {
        if let w = window { NSApp.activate(ignoringOtherApps: true); w.makeKeyAndOrderFront(nil); return }
        let m = ColorMatchModel(displayID: displayID, displayKey: displayKey, displayName: displayName)
        let w = NSWindow(contentRect: .zero, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        w.title = "맥북과 색 맞추기"
        w.isReleasedWhenClosed = false
        w.delegate = self
        w.contentView = NSHostingView(rootView: ColorMatchView(model: m, close: { [weak w] in w?.close() }))
        m.onHideWindow = { [weak w] hide in
            if hide { w?.orderOut(nil) } else { NSApp.activate(ignoringOtherApps: true); w?.makeKeyAndOrderFront(nil) }
        }
        // 맥북 화면에 띄움 (외장 모니터는 측정 대상)
        if let mac = NSScreen.screens.first(where: { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber).map { CGDisplayIsBuiltin($0.uint32Value) != 0 } ?? false }) {
            w.setFrameOrigin(NSPoint(x: mac.visibleFrame.midX - 260, y: mac.visibleFrame.midY - 250))
        } else {
            w.center()
        }
        window = w
        model = m
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
        m.appear()
    }

    func windowWillClose(_ notification: Notification) {
        model?.disappear()
        model = nil
        window = nil
    }
}
