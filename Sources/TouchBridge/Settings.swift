import CoreGraphics
import Foundation

/// 패널 정규화 좌표(0…1) → 화면 정규화 좌표(0…1) 아핀 변환.
///   sx = a·u + b·v + c
///   sy = d·u + e·v + f
/// 4포인트 보정을 최소제곱으로 풀어 얻으며, 회전/반전/축 교환/기울어짐까지 흡수한다.
struct AffineCalibration: Codable, Equatable {
    var a, b, c, d, e, f: Double

    static let identity = AffineCalibration(a: 1, b: 0, c: 0, d: 0, e: 1, f: 0)

    func apply(_ p: CGPoint) -> CGPoint {
        CGPoint(x: a * p.x + b * p.y + c, y: d * p.x + e * p.y + f)
    }

    /// raw[i] → screen[i] 대응점으로 최소제곱 아핀 변환을 구한다.
    static func solve(raw: [CGPoint], screen: [CGPoint]) -> AffineCalibration? {
        guard raw.count == screen.count, raw.count >= 3 else { return nil }
        var m = [[Double]](repeating: [0, 0, 0], count: 3)
        var rx = [0.0, 0.0, 0.0], ry = [0.0, 0.0, 0.0]
        for (r, s) in zip(raw, screen) {
            let v = [Double(r.x), Double(r.y), 1.0]
            for i in 0..<3 {
                for j in 0..<3 { m[i][j] += v[i] * v[j] }
                rx[i] += v[i] * s.x
                ry[i] += v[i] * s.y
            }
        }
        guard let p = solve3(m, rx), let q = solve3(m, ry) else { return nil }
        return AffineCalibration(a: p[0], b: p[1], c: p[2], d: q[0], e: q[1], f: q[2])
    }

    /// 3x3 선형 방정식 (크래머 공식)
    private static func solve3(_ m: [[Double]], _ b: [Double]) -> [Double]? {
        func det(_ a: [[Double]]) -> Double {
            a[0][0] * (a[1][1] * a[2][2] - a[1][2] * a[2][1])
                - a[0][1] * (a[1][0] * a[2][2] - a[1][2] * a[2][0])
                + a[0][2] * (a[1][0] * a[2][1] - a[1][1] * a[2][0])
        }
        let d = det(m)
        guard abs(d) > 1e-12 else { return nil }
        return (0..<3).map { col in
            var mc = m
            for row in 0..<3 { mc[row][col] = b[row] }
            return det(mc) / d
        }
    }
}

final class AppSettings {
    static let shared = AppSettings()
    private let ud = UserDefaults.standard

    private enum Key {
        static let enabled = "touchEnabled"
        static let target = "targetDisplayKey"
        static let calibrations = "calibrations"
        static let pinchGain = "pinchGain"
        static let keepMonitor = "keepMonitorSettings"
        static let monitorValues = "monitorValues"
    }

    /// 외장 모니터가 켜질 때 밝기·명암·음량을 마지막 값으로 되돌릴지
    var keepMonitorSettings: Bool {
        get { ud.object(forKey: Key.keepMonitor) as? Bool ?? true }
        set { ud.set(newValue, forKey: Key.keepMonitor) }
    }

    /// 모니터별(DisplayInfo.key) 기억한 DDC 값: VCP 코드 → 값. UserDefaults 는 스레드 안전하므로 DDC 큐에서도 사용.
    func monitorValues(for key: String) -> [UInt8: Int] {
        let all = ud.dictionary(forKey: Key.monitorValues) as? [String: [String: Int]] ?? [:]
        var out: [UInt8: Int] = [:]
        for (k, v) in all[key] ?? [:] { if let c = UInt8(k) { out[c] = v } }
        return out
    }

    func setMonitorValue(_ value: Int, code: UInt8, for key: String) {
        var all = ud.dictionary(forKey: Key.monitorValues) as? [String: [String: Int]] ?? [:]
        all[key, default: [:]][String(code)] = value
        ud.set(all, forKey: Key.monitorValues)
    }

    /// 핀치 줌 감도: 출력 배율 = (손가락 간격 비율)^gain. 1.0이면 손가락과 1:1
    var pinchGain: Double {
        get { ud.object(forKey: Key.pinchGain) as? Double ?? 0.5 }
        set { ud.set(newValue, forKey: Key.pinchGain) }
    }

    var touchEnabled: Bool {
        get { ud.object(forKey: Key.enabled) as? Bool ?? true }
        set { ud.set(newValue, forKey: Key.enabled) }
    }

    /// 사용자가 고른 모니터의 안정적 식별자 (DisplayInfo.key). nil이면 자동 선택.
    var targetDisplayKey: String? {
        get { ud.string(forKey: Key.target) }
        set { ud.set(newValue, forKey: Key.target) }
    }

    private var calibrations: [String: AffineCalibration] {
        get {
            guard let data = ud.data(forKey: Key.calibrations),
                  let dict = try? JSONDecoder().decode([String: AffineCalibration].self, from: data)
            else { return [:] }
            return dict
        }
        set { ud.set(try? JSONEncoder().encode(newValue), forKey: Key.calibrations) }
    }

    func calibration(for key: String) -> AffineCalibration? { calibrations[key] }

    func setCalibration(_ cal: AffineCalibration?, for key: String) {
        var all = calibrations
        all[key] = cal
        calibrations = all
    }
}
