import AppKit

/// 외장 모니터 색의 소프트웨어 미세 보정 (감마 테이블).
/// DDC 게인은 한 단계가 크게 움직이는 모니터가 많아서(제우스랩: 약 7%), 남은 차이를 여기서 메운다.
/// 여러 회색 단계(어두움·중간·밝음)마다 채널별 배율을 두고 그 사이는 보간한다.
///
/// - 맥북(내장) 화면의 테이블은 절대 건드리지 않는다.
/// - 원래 테이블(색상 프로파일)에 곱해서 적용하므로 프로파일을 덮어쓰지 않는다.
/// - macOS는 앱 종료·재연결·잠자기 해제·프로파일 변경 때 테이블을 되돌린다 → 감지해서 다시 적용.
/// 모든 메서드는 메인 스레드에서 호출.
final class GammaCorrector {
    static let shared = GammaCorrector()

    /// levels: 외장 모니터에 보내는 값(sRGB 0~1), r/g/b: 그 단계에서 곱할 선형 밝기 배율(≤1)
    struct Correction: Codable, Equatable {
        var levels: [Double]
        var r: [Double], g: [Double], b: [Double]
        static func identity(_ levels: [Double]) -> Correction {
            let one = levels.map { _ in 1.0 }
            return Correction(levels: levels, r: one, g: one, b: one)
        }
    }

    private let defaultsKey = "gammaCorrections"
    private var base: [CGDirectDisplayID: [[CGGammaValue]]] = [:]       // 우리가 손대기 전 테이블
    private var lastApplied: [CGDirectDisplayID: [[CGGammaValue]]] = [:]
    private var timer: Timer?
    private var lastCorrection: [CGDirectDisplayID: Correction] = [:]
    /// 색 맞추기 중에는 저장된 보정을 자동으로 다시 넣지 않음
    var paused: Set<String> = []

    func start() {
        NotificationCenter.default.addObserver(forName: .displaysDidChange, object: nil, queue: .main) { [weak self] _ in
            self?.base.removeAll()          // 재연결되면 macOS가 테이블을 프로파일 값으로 되돌림
            self?.lastApplied.removeAll()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self?.applyAll() }
        }
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification] {
            NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self?.applyAll() }
            }
        }
        // 프로파일 변경 등으로 조용히 되돌려진 경우 대비
        timer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in self?.applyAll() }
        applyAll()
    }

    // MARK: 저장

    func correction(for key: String) -> Correction? {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let all = try? JSONDecoder().decode([String: Correction].self, from: data) else { return nil }
        return all[key]
    }

    func setCorrection(_ c: Correction?, for key: String) {
        var all: [String: Correction] = [:]
        if let data = UserDefaults.standard.data(forKey: defaultsKey),
           let decoded = try? JSONDecoder().decode([String: Correction].self, from: data) { all = decoded }
        all[key] = c
        UserDefaults.standard.set(try? JSONEncoder().encode(all), forKey: defaultsKey)
        applyAll()
    }

    // MARK: 적용

    /// 저장된 보정을 연결된 외장 모니터에 적용 (이미 적용돼 있으면 아무것도 안 함)
    func applyAll() {
        for d in DisplayManager.shared.displays where !d.isBuiltin && !paused.contains(d.key) {
            if let c = correction(for: d.key) { apply(c, to: d.id) } else { restore(d.id) }
        }
    }

    /// 보정 적용 (저장하지 않음 — 색 맞추기 도중 시험용으로도 사용)
    func apply(_ c: Correction, to id: CGDirectDisplayID) {
        guard CGDisplayIsBuiltin(id) == 0, let cur = Self.read(id) else { return }
        // 지금 테이블이 우리가 마지막으로 넣은 것과 다르면 처음이거나 macOS가 되돌린 것 → 지금 테이블이 새 기준
        if lastApplied[id] == nil || cur != lastApplied[id] { base[id] = cur }
        else if lastCorrection[id] == c { return }   // 이미 같은 보정이 들어가 있음
        guard let b = base[id] else { return }
        let out = (0..<3).map { ch in
            b[ch].enumerated().map { i, v -> CGGammaValue in
                let x = Double(i) / Double(b[ch].count - 1)
                return CGGammaValue(Self.encode(Self.linear(Double(v)) * Self.multiplier(c, channel: ch, at: x)))
            }
        }
        guard CGSetDisplayTransferByTable(id, UInt32(out[0].count), out[0], out[1], out[2]) == .success else { return }
        lastApplied[id] = Self.read(id) ?? out   // 저장 시 양자화될 수 있어 다시 읽은 값을 기억
        lastCorrection[id] = c
    }

    /// 보정 해제: 기준 테이블로 되돌림
    func restore(_ id: CGDirectDisplayID) {
        guard let b = base[id], lastApplied[id] != nil else { return }
        CGSetDisplayTransferByTable(id, UInt32(b[0].count), b[0], b[1], b[2])
        lastApplied[id] = nil
        lastCorrection[id] = nil
        base[id] = nil
    }

    private static func multiplier(_ c: Correction, channel: Int, at x: Double) -> Double {
        let m = channel == 0 ? c.r : channel == 1 ? c.g : c.b
        guard let first = c.levels.first, let last = c.levels.last else { return 1 }
        if x <= first { return m[0] }
        if x >= last { return m[m.count - 1] }
        for i in 1..<c.levels.count where x <= c.levels[i] {
            let t = (x - c.levels[i - 1]) / (c.levels[i] - c.levels[i - 1])
            return m[i - 1] + (m[i] - m[i - 1]) * t
        }
        return m[m.count - 1]
    }

    private static func read(_ id: CGDirectDisplayID) -> [[CGGammaValue]]? {
        let cap = CGDisplayGammaTableCapacity(id)
        guard cap > 0 else { return nil }
        var r = [CGGammaValue](repeating: 0, count: Int(cap)), g = r, b = r
        var count: UInt32 = 0
        guard CGGetDisplayTransferByTable(id, cap, &r, &g, &b, &count) == .success, count > 1 else { return nil }
        return [Array(r.prefix(Int(count))), Array(g.prefix(Int(count))), Array(b.prefix(Int(count)))]
    }

    static func linear(_ x: Double) -> Double { x <= 0.04045 ? x / 12.92 : pow((x + 0.055) / 1.055, 2.4) }
    static func encode(_ y: Double) -> Double {
        let v = y <= 0.0031308 ? y * 12.92 : 1.055 * pow(max(y, 0), 1 / 2.4) - 0.055
        return min(1, max(0, v))
    }
}
