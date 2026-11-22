import AppKit
import QuartzCore

/// 대상 모니터의 화면 갱신(vsync)에 맞춰 콜백을 부르는 타이머.
/// macOS 14+에서는 NSScreen.displayLink, 그 이전에는 120Hz Timer로 대체한다.
final class FrameTicker: NSObject {
    /// dt: 직전 틱 이후 경과 시간(초)
    var onTick: ((Double) -> Void)?
    private var link: AnyObject?
    private var timer: Timer?
    private var last: CFTimeInterval = 0

    var isRunning: Bool { link != nil || timer != nil }

    /// - Parameter point: 전역 CG 좌표. 이 점이 있는 모니터의 주사율에 맞춘다.
    func start(near point: CGPoint) {
        guard !isRunning else { return }
        last = CACurrentMediaTime()
        if #available(macOS 14.0, *), let screen = Self.screen(containing: point) {
            let l = screen.displayLink(target: self, selector: #selector(linkFired(_:)))
            l.add(to: .main, forMode: .common)
            link = l
        } else {
            let t = Timer(timeInterval: 1.0 / 120, repeats: true) { [weak self] _ in self?.fire() }
            RunLoop.main.add(t, forMode: .common)
            timer = t
        }
    }

    func stop() {
        if #available(macOS 14.0, *), let l = link as? CADisplayLink { l.invalidate() }
        link = nil
        timer?.invalidate()
        timer = nil
    }

    @available(macOS 14.0, *)
    @objc private func linkFired(_ l: CADisplayLink) { fire() }

    private func fire() {
        let now = CACurrentMediaTime()
        let dt = min(max(now - last, 1.0 / 240), 1.0 / 20)
        last = now
        onTick?(dt)
    }

    private static func screen(containing p: CGPoint) -> NSScreen? {
        var id: CGDirectDisplayID = 0
        var count: UInt32 = 0
        guard CGGetDisplaysWithPoint(p, 1, &id, &count) == .success, count > 0 else { return nil }
        return DisplayManager.screen(for: id)
    }
}
