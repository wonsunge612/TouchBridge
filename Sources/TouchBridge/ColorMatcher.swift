import AppKit

/// 아이폰 카메라로 맥북 화면과 외장 모니터를 한 프레임에 찍어, 외장 모니터의 RGB 게인(DDC)을
/// 맥북과 같은 흰색으로 보이도록 조금씩 조절한다.
///
/// 카메라의 자동 화이트밸런스·노출은 끌 수 없지만, 두 화면이 같은 프레임에 있으면 두 화면에 똑같이 적용되므로
/// "어느 쪽이 더 붉은가"의 상대 비교는 안정적이다 (실측 흔들림 약 ±0.5%).
/// 모든 DDC 작업은 DDC.queue 에서 하므로, 도중의 값이 '모니터 설정 유지'에 기억되지 않는다.
final class ColorMatcher {
    struct Errors { var red: Double; var blue: Double }   // 외장 모니터가 맥북보다 붉은/푸른 정도 (0.05 = 5%)
    struct Outcome {
        let before: Errors, after: Errors
        let originalGains: [UInt8: Int], finalGains: [UInt8: Int]
    }
    enum Event {
        case status(String)
        case finished(Outcome)
        case failed(String)
    }

    static let redGain: UInt8 = 0x16, greenGain: UInt8 = 0x18, blueGain: UInt8 = 0x1A
    private let tolerance = 0.015
    private let maxIterations = 24

    private let displayID: CGDirectDisplayID
    private let displayKey: String
    private let camera: CameraSampler
    private let patches: PatchWindows
    private let onEvent: (Event) -> Void
    private let cancelLock = NSLock()
    private var cancelled = false

    init(displayID: CGDirectDisplayID, displayKey: String, camera: CameraSampler, patches: PatchWindows,
         onEvent: @escaping (Event) -> Void) {
        self.displayID = displayID
        self.displayKey = displayKey
        self.camera = camera
        self.patches = patches
        self.onEvent = onEvent
    }

    func start() { DDC.queue.async { [self] in run() } }

    func cancel() {
        cancelLock.lock(); cancelled = true; cancelLock.unlock()
    }

    private var isCancelled: Bool { cancelLock.lock(); defer { cancelLock.unlock() }; return cancelled }

    private func emit(_ e: Event) { DispatchQueue.main.async { self.onEvent(e) } }

    // MARK: DDC.queue

    private struct Stop: Error { let message: String }

    private func run() {
        guard let ch = DDC.channels()[displayID] else { return emit(.failed("이 모니터의 DDC 통로를 찾지 못했습니다.")) }
        var original: [UInt8: Int] = [:]
        for c in [Self.redGain, Self.greenGain, Self.blueGain] { if let v = ch.read(c)?.value { original[c] = v } }
        guard original.count == 3 else { return emit(.failed("이 모니터는 RGB 게인 조절을 지원하지 않습니다.")) }
        Diag.log("색 맞추기 시작: 원래 게인 R\(original[Self.redGain]!) G\(original[Self.greenGain]!) B\(original[Self.blueGain]!)")

        do {
            let outcome = try match(ch, original: original)
            for (c, v) in outcome.finalGains { AppSettings.shared.setMonitorValue(v, code: c, for: displayKey) }
            Diag.log(String(format: "색 맞추기 완료: 붉은 기 %+.1f%%→%+.1f%%, 푸른 기 %+.1f%%→%+.1f%%, 게인 R%d B%d",
                            outcome.before.red * 100, outcome.after.red * 100, outcome.before.blue * 100, outcome.after.blue * 100,
                            outcome.finalGains[Self.redGain]!, outcome.finalGains[Self.blueGain]!))
            emit(.finished(outcome))
        } catch let s as Stop {
            for (c, v) in original { ch.write(c, v) }
            Diag.log("색 맞추기 중단: \(s.message) — 원래 게인으로 되돌림")
            emit(.failed(s.message))
        } catch {
            for (c, v) in original { ch.write(c, v) }
            emit(.failed(error.localizedDescription))
        }
        patches.hide()
    }

    /// 원래 게인으로 되돌리기 (결과 화면의 '원래대로')
    static func revert(displayID: CGDirectDisplayID, displayKey: String, to gains: [UInt8: Int], done: @escaping () -> Void) {
        DDC.queue.async {
            if let ch = DDC.channels()[displayID] { for (c, v) in gains { ch.write(c, v) } }
            for (c, v) in gains { AppSettings.shared.setMonitorValue(v, code: c, for: displayKey) }
            Diag.log("색 맞추기: 원래 게인으로 되돌림")
            DispatchQueue.main.async(execute: done)
        }
    }

    private func check() throws { if isCancelled { throw Stop(message: "취소했습니다.") } }

    private func frame(_ n: Int = 8) throws -> [Float] {
        try check()
        guard let f = camera.average(n) else { throw Stop(message: "카메라 영상이 들어오지 않습니다. 아이폰이 잠겨 있고 움직이지 않는지 확인하세요.") }
        return f
    }

    private func match(_ ch: DDCChannel, original: [UInt8: Int]) throws -> Outcome {
        let level: CGFloat = 0.7   // 흰색(1.0)은 카메라에서 포화되기 쉬워 밝은 회색 사용
        emit(.status("화면 위치 찾는 중…"))
        patches.show(mac: 0, ext: 0); let off = try frame()
        patches.show(mac: level, ext: 0); let onMac = try frame()
        patches.show(mac: 0, ext: level); let onExt = try frame()
        let W = camera.width, H = camera.height
        guard let mMac = Self.region(on: onMac, off: off, w: W, h: H),
              let mExt = Self.region(on: onExt, off: off, w: W, h: H) else {
            throw Stop(message: "두 화면이 카메라에 다 보이지 않습니다. 아이폰이 맥북과 외장 모니터를 함께 보도록 놓아 주세요.")
        }

        // 카메라에서 두 화면 밝기가 같아지도록 더 밝은 쪽 회색을 낮춤 (밝기 차이가 색 비교를 틀어지게 하지 않도록)
        emit(.status("밝기 맞추는 중…"))
        var macLevel = level, extLevel = level
        for _ in 0..<3 {
            patches.show(mac: macLevel, ext: extLevel)
            let f = try frame()
            let a = Self.measure(f, mMac), b = Self.measure(f, mExt)
            guard a.g > 0.01, b.g > 0.01 else { throw Stop(message: "화면이 너무 어둡게 찍힙니다.") }
            if abs(a.g / b.g - 1) < 0.03 { break }
            if a.g > b.g { macLevel = Self.encode(Self.linear(Float(macLevel)) * b.g / a.g) }
            else { extLevel = Self.encode(Self.linear(Float(extLevel)) * a.g / b.g) }
        }
        patches.show(mac: macLevel, ext: extLevel)

        var gains = original
        func errors() throws -> Errors {
            let f = try frame(10)
            let a = Self.measure(f, mMac), b = Self.measure(f, mExt)
            return Errors(red: Double((b.r / b.g) / (a.r / a.g) - 1), blue: Double((b.b / b.g) / (a.b / a.g) - 1))
        }
        let before = try errors()
        var e = before
        var best = (score: max(abs(e.red), abs(e.blue)), gains: gains, errors: e)
        var slope: [UInt8: Double] = [Self.redGain: 0.03, Self.blueGain: 0.03]   // 게인 1당 비율 변화 (시작 추정치)
        var lastSign: [UInt8: Double] = [:], flips: [UInt8: Int] = [:]
        var within = 0

        for i in 1...maxIterations {
            if abs(e.red) <= tolerance && abs(e.blue) <= tolerance {
                within += 1
                if within >= 2 { break }   // 흔들림으로 우연히 맞은 게 아닌지 한 번 더 확인
            } else { within = 0 }
            emit(.status(String(format: "색 맞추는 중… (%d) 붉은 기 %+.1f%%, 푸른 기 %+.1f%%", i, e.red * 100, e.blue * 100)))

            var moved: [UInt8: Int] = [:]
            for (code, err) in [(Self.redGain, e.red), (Self.blueGain, e.blue)] where abs(err) > tolerance * 0.7 {
                let sign: Double = err > 0 ? 1 : -1   // 너무 붉으면(+) 빨강 게인을 낮춤
                if let ls = lastSign[code], ls != sign { flips[code, default: 0] += 1 }
                lastSign[code] = sign
                let step = (flips[code, default: 0] >= 2) ? 1 : Int(max(1, min(4, (abs(err) / slope[code]!).rounded())))
                let next = min(100, max(0, gains[code]! - Int(sign) * step))
                if next != gains[code]! { moved[code] = next - gains[code]! ; gains[code] = next; ch.write(code, next) }
            }
            if moved.isEmpty { break }   // 더 움직일 수 없음 (끝값)
            Thread.sleep(forTimeInterval: 1.2)   // 모니터 적용 + 카메라 자동 노출·화이트밸런스 안정
            let prev = e
            e = try errors()
            // 실제 반응으로 기울기 갱신
            for (code, d) in moved {
                let change = code == Self.redGain ? abs(e.red - prev.red) : abs(e.blue - prev.blue)
                if change > 0.002 { slope[code] = min(0.2, max(0.003, change / Double(abs(d)))) }
            }
            let score = max(abs(e.red), abs(e.blue))
            if score < best.score { best = (score, gains, e) }
            if flips.values.allSatisfy({ $0 >= 4 }) && !flips.isEmpty { break }   // 맞출 수 있는 한계에서 왔다 갔다
        }

        if best.gains != gains {
            for c in [Self.redGain, Self.blueGain] where best.gains[c] != gains[c] { ch.write(c, best.gains[c]!) }
            Thread.sleep(forTimeInterval: 1.2)
            e = try errors()
        }
        return Outcome(before: before, after: e, originalGains: original, finalGains: best.gains)
    }

    // MARK: 영상 분석

    static func linear(_ x: Float) -> Float { x <= 0.04045 ? x / 12.92 : powf((x + 0.055) / 1.055, 2.4) }
    static func encode(_ y: Float) -> CGFloat {
        let v = y <= 0.0031308 ? y * 12.92 : 1.055 * powf(y, 1 / 2.4) - 0.055
        return CGFloat(min(1, max(0.05, v)))
    }

    static func measure(_ f: [Float], _ m: [Int]) -> (r: Float, g: Float, b: Float) {
        var r: Float = 0, g: Float = 0, b: Float = 0
        for i in m { r += linear(f[i * 3]); g += linear(f[i * 3 + 1]); b += linear(f[i * 3 + 2]) }
        let n = Float(max(m.count, 1))
        return (r / n, g / n, b / n)
    }

    /// 켰을 때 밝아진 가장 큰 덩어리를 화면으로 보고, 그 안쪽 띠(가로 가운데 50%, 세로 20~60%)만 측정 영역으로 쓴다.
    /// 가장자리는 시야각에 따른 색 변화가 크고, 화면 아래쪽에는 책상·키보드 반사광이 붙기 때문.
    static func region(on: [Float], off: [Float], w W: Int, h H: Int) -> [Int]? {
        let n = W * H
        guard on.count == n * 3, off.count == n * 3 else { return nil }
        var d = [Float](repeating: 0, count: n)
        for i in 0..<n {
            let a = 0.2126 * on[i*3] + 0.7152 * on[i*3+1] + 0.0722 * on[i*3+2]
            let b = 0.2126 * off[i*3] + 0.7152 * off[i*3+1] + 0.0722 * off[i*3+2]
            d[i] = a - b
        }
        guard let mx = d.max(), mx > 0.05 else { return nil }
        var seen = [Bool](repeating: false, count: n), best: [Int] = []
        for s in 0..<n where d[s] > mx * 0.3 && !seen[s] {
            var stack = [s], comp: [Int] = []
            seen[s] = true
            while let i = stack.popLast() {
                comp.append(i)
                let x = i % W, y = i / W
                for (nx, ny) in [(x - 1, y), (x + 1, y), (x, y - 1), (x, y + 1)] where nx >= 0 && ny >= 0 && nx < W && ny < H {
                    let j = ny * W + nx
                    if !seen[j] && d[j] > mx * 0.3 { seen[j] = true; stack.append(j) }
                }
            }
            if comp.count > best.count { best = comp }
        }
        guard best.count > 300 else { return nil }
        let med = best.map { d[$0] }.sorted()[best.count / 2]
        best = best.filter { d[$0] >= med * 0.55 }
        let xs = best.map { $0 % W }, ys = best.map { $0 / W }
        guard let x0 = xs.min(), let x1 = xs.max(), let y0 = ys.min(), let y1 = ys.max() else { return nil }
        let cx0 = x0 + (x1 - x0) / 4, cx1 = x1 - (x1 - x0) / 4
        let cy0 = y0 + (y1 - y0) * 2 / 10, cy1 = y0 + (y1 - y0) * 6 / 10
        let m = best.filter { let x = $0 % W, y = $0 / W; return x >= cx0 && x <= cx1 && y >= cy0 && y <= cy1 }
        return m.count > 100 ? m : nil
    }
}

/// 두 화면을 덮는 측정용 단색 창. 아무 스레드에서나 부를 수 있다 (메인에서 실행).
final class PatchWindows {
    private var mac: NSWindow?
    private var ext: NSWindow?
    private let macScreen: NSScreen, extScreen: NSScreen
    var onCancel: (() -> Void)?

    init(macScreen: NSScreen, extScreen: NSScreen) {
        self.macScreen = macScreen
        self.extScreen = extScreen
    }

    func show(mac m: CGFloat, ext e: CGFloat) {
        onMain {
            if self.mac == nil {
                self.mac = self.make(self.macScreen, key: true)
                self.ext = self.make(self.extScreen, key: false)
            }
            self.mac?.backgroundColor = NSColor(srgbRed: m, green: m, blue: m, alpha: 1)
            self.ext?.backgroundColor = NSColor(srgbRed: e, green: e, blue: e, alpha: 1)
        }
        Thread.sleep(forTimeInterval: 0.6)   // 화면 반영 + 카메라 적응
    }

    func hide() {
        onMain {
            self.mac?.orderOut(nil); self.ext?.orderOut(nil)
            self.mac = nil; self.ext = nil
        }
    }

    private func make(_ s: NSScreen, key: Bool) -> NSWindow {
        let w = KeyCatchingWindow(contentRect: s.frame, styleMask: .borderless, backing: .buffered, defer: false)
        w.level = .screenSaver
        w.backgroundColor = .black
        w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        w.isReleasedWhenClosed = false
        w.onEscape = { [weak self] in self?.onCancel?() }
        w.setFrame(s.frame, display: true)
        if key {
            // 측정 영역(세로 20~60%)을 피해 맨 아래에 안내 문구
            let label = NSTextField(labelWithString: "외장 모니터 색 맞추는 중 — ESC로 취소")
            label.textColor = .gray
            label.font = .systemFont(ofSize: 13)
            label.sizeToFit()
            label.frame.origin = CGPoint(x: (s.frame.width - label.frame.width) / 2, y: 24)
            w.contentView?.addSubview(label)
            NSApp.activate(ignoringOtherApps: true)
            w.makeKeyAndOrderFront(nil)
        } else {
            w.orderFrontRegardless()
        }
        return w
    }

    private func onMain(_ f: @escaping () -> Void) {
        if Thread.isMainThread { f() } else { DispatchQueue.main.sync(execute: f) }
    }
}

private final class KeyCatchingWindow: NSWindow {
    var onEscape: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onEscape?() } else { super.keyDown(with: event) }
    }
}
