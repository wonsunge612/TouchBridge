import AppKit
import SwiftUI

/// 4포인트 보정 진행 상태
final class CalibrationModel: ObservableObject {
    /// 화면 정규화 좌표 (좌상단 원점) — 좌상, 우상, 우하, 좌하
    let targets: [CGPoint] = [
        CGPoint(x: 0.1, y: 0.1), CGPoint(x: 0.9, y: 0.1),
        CGPoint(x: 0.9, y: 0.9), CGPoint(x: 0.1, y: 0.9),
    ]

    @Published private(set) var step = 0
    @Published private(set) var pressing = false
    @Published private(set) var message = "표시된 십자선 중심을 정확히 터치했다가 떼세요."
    @Published private(set) var finished = false

    var onComplete: ((AffineCalibration) -> Void)?
    private var samples: [CGPoint] = []
    private var current: [CGPoint] = []

    func handle(raw: CGPoint, down: Bool) {
        guard !finished else { return }
        if down {
            if !pressing { pressing = true; current.removeAll() }
            current.append(raw)
            return
        }
        guard pressing else { return }
        pressing = false
        // 접촉 직후 흔들림을 제외하고 평균
        let pts = current.count > 4 ? Array(current.dropFirst(2)) : current
        guard !pts.isEmpty else { return }
        let avg = CGPoint(x: pts.map(\.x).reduce(0, +) / CGFloat(pts.count),
                          y: pts.map(\.y).reduce(0, +) / CGFloat(pts.count))
        if samples.contains(where: { hypot($0.x - avg.x, $0.y - avg.y) < 0.05 }) {
            message = "이전 점과 너무 가깝습니다. 빨간 십자선을 터치하세요."
            return
        }
        samples.append(avg)
        step = samples.count
        if step < targets.count {
            message = "좋습니다. 다음 점을 터치하세요. (\(step)/\(targets.count))"
        } else {
            finish()
        }
    }

    func restart() {
        samples.removeAll()
        current.removeAll()
        step = 0
        pressing = false
        finished = false
        message = "표시된 십자선 중심을 정확히 터치했다가 떼세요."
    }

    private func finish() {
        guard let cal = AffineCalibration.solve(raw: samples, screen: targets) else {
            fail("보정값을 계산할 수 없습니다.")
            return
        }
        // 잔차 검사: 4점이 하나의 아핀 변환으로 설명되지 않으면 잘못 터치한 것
        let maxErr = zip(samples, targets).map { r, t -> CGFloat in
            let p = cal.apply(r)
            return hypot(p.x - t.x, p.y - t.y)
        }.max() ?? 1
        guard maxErr < 0.04 else {
            fail(String(format: "점들이 일관되지 않습니다 (오차 %.1f%%). 다시 시도합니다.", maxErr * 100))
            return
        }
        finished = true
        message = "보정 완료! 저장되었습니다."
        onComplete?(cal)
    }

    private func fail(_ msg: String) {
        restart()
        message = msg
    }
}

struct CalibrationView: View {
    @ObservedObject var model: CalibrationModel
    let displayName: String
    let onCancel: () -> Void

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.black
                // 완료된 점은 회색, 현재 점은 강조
                ForEach(Array(model.targets.enumerated()), id: \.offset) { i, t in
                    Crosshair(state: i < model.step ? .done : (i == model.step && !model.finished ? .active(model.pressing) : .pending))
                        .position(x: t.x * geo.size.width, y: t.y * geo.size.height)
                }
                VStack(spacing: 14) {
                    Text("터치 보정 — \(displayName)")
                        .font(.system(size: 30, weight: .semibold))
                    Text(model.message)
                        .font(.system(size: 18))
                        .foregroundColor(model.finished ? .green : .white.opacity(0.85))
                    Text("ESC 취소   ·   R 다시 시작")
                        .font(.system(size: 13))
                        .foregroundColor(.white.opacity(0.5))
                    Button("취소", action: onCancel)
                        .keyboardShortcut(.cancelAction)
                        .padding(.top, 8)
                }
                .foregroundColor(.white)
                .multilineTextAlignment(.center)
                .frame(maxWidth: geo.size.width * 0.6)
            }
        }
        .ignoresSafeArea()
    }
}

struct Crosshair: View {
    enum State: Equatable { case pending, active(Bool), done }
    let state: State

    var body: some View {
        let color: Color = {
            switch state {
            case .pending: return .white.opacity(0.15)
            case .active(let pressing): return pressing ? .green : .red
            case .done: return .white.opacity(0.4)
            }
        }()
        ZStack {
            Circle().stroke(color, lineWidth: 2).frame(width: 56, height: 56)
            Rectangle().fill(color).frame(width: 2, height: 90)
            Rectangle().fill(color).frame(width: 90, height: 2)
            Circle().fill(color).frame(width: 8, height: 8)
        }
        .scaleEffect(state == .active(false) ? 1.15 : 1)
        .animation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true), value: state == .active(false))
    }
}

private final class CalibrationPanelWindow: NSWindow {
    var onKey: ((NSEvent) -> Bool)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    override func keyDown(with event: NSEvent) {
        if onKey?(event) != true { super.keyDown(with: event) }
    }
}

/// 대상 모니터 전체를 덮는 보정 창
final class CalibrationWindowController {
    private var window: CalibrationPanelWindow?
    private var model: CalibrationModel?
    private var displayObserver: NSObjectProtocol?
    private weak var controller: TouchController?
    private var display: DisplayInfo?

    var isOpen: Bool { window != nil }

    func show(controller: TouchController) {
        if let w = window { w.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return }
        guard let display = controller.targetDisplay,
              let screen = DisplayManager.screen(for: display.id) else { NSSound.beep(); return }
        self.controller = controller
        self.display = display

        let model = CalibrationModel()
        model.onComplete = { [weak self] cal in
            controller.settings.setCalibration(cal, for: display.calibrationKey)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { self?.close() }
        }
        self.model = model

        let w = CalibrationPanelWindow(contentRect: screen.frame, styleMask: .borderless,
                                       backing: .buffered, defer: false)
        w.level = .screenSaver
        w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        w.backgroundColor = .black
        w.isReleasedWhenClosed = false
        w.contentView = NSHostingView(rootView: CalibrationView(
            model: model, displayName: display.name, onCancel: { [weak self] in self?.close() }))
        w.onKey = { [weak self, weak model] e in
            switch e.keyCode {
            case 53: self?.close(); return true                 // ESC
            case 15: model?.restart(); return true              // R
            default: return false
            }
        }
        w.setFrame(screen.frame, display: true)
        window = w

        // 보정 중 해상도/배치가 바뀌면 창을 다시 맞추고, 모니터가 사라지면 취소
        displayObserver = NotificationCenter.default.addObserver(forName: .displaysDidChange, object: nil, queue: .main) {
            [weak self] _ in
            guard let self, let d = self.display else { return }
            if let s = DisplayManager.screen(for: d.id) { self.window?.setFrame(s.frame, display: true) }
            else { self.close() }
        }

        controller.beginCalibration { [weak model] raw, down in model?.handle(raw: raw, down: down) }
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
    }

    func close() {
        guard let w = window else { return }
        window = nil
        if let o = displayObserver { NotificationCenter.default.removeObserver(o) }
        displayObserver = nil
        controller?.endCalibration()
        w.orderOut(nil)
        model = nil
    }
}
