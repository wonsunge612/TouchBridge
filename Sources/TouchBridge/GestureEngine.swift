import CoreGraphics
import Foundation

/// 제스처 엔진의 출력 (EventInjector가 구현, 테스트에서는 기록용 스텁)
protocol EventOutput: AnyObject {
    func move(_ p: CGPoint)
    func down(_ p: CGPoint)
    func drag(_ p: CGPoint)
    func up(_ p: CGPoint)
    func rightClick(_ p: CGPoint)
    func forceUp(at p: CGPoint?)
    func scroll(dx: Double, dy: Double, at p: CGPoint, phase: ScrollPhase, momentum: MomentumPhase)
    /// 트랙패드 핀치와 같은 magnify 제스처. m: 이번 이벤트의 배율 변화 (새 배율 = 이전 × (1 + m))
    func magnify(_ m: Double, phase: ScrollPhase, at p: CGPoint)
}

enum ScrollPhase: Int64 { case none = 0, began = 1, changed = 2, ended = 4, cancelled = 8, mayBegin = 128 }
enum MomentumPhase: Int64 { case none = 0, begin = 1, `continue` = 2, end = 3 }

extension EventOutput {
    func forceUp() { forceUp(at: nil) }
    func scroll(dx: Double, dy: Double, at p: CGPoint, phase: ScrollPhase) {
        scroll(dx: dx, dy: dy, at: p, phase: phase, momentum: .none)
    }
}

/// 화면 좌표로 변환된 접점들을 받아 클릭/드래그/두 손가락 스크롤로 해석한다.
///
///  한 손가락:  닿는 즉시 커서 이동(hover) → 탭이면 원위치 클릭,
///              움직이면 드래그, 가만히 길게 누르면 그 자리에서 마우스 다운
///  두 손가락:  함께 이동 → 트랙패드식 픽셀 스크롤(관성 포함, 콘텐츠가 손가락을 따라감)
///              벌리기/오므리기 → 핀치 줌 (magnify 제스처)
///              한 제스처 안에서는 처음 결정된 모드(스크롤/줌)로 고정.
///              두 손가락 제스처 중에는 어떤 클릭도 만들지 않는다.
final class GestureEngine {
    struct Tuning {
        /// 이 거리 안의 흔들림은 탭으로 간주 (포인트)
        var tapSlop: CGFloat = 10
        /// 첫 손가락이 움직여도 이 시간 동안은 두 번째 손가락을 기다린다 (드래그 확정 보류)
        var secondFingerWindow: CFTimeInterval = 0.25
        /// 가만히 누르고 있을 때 마우스 다운을 보내기까지의 시간
        var holdDelay: CFTimeInterval = 0.35
        /// 두 손가락 제스처가 끝난 뒤 한 손가락 탭/드래그를 무시하는 시간 (떼는 순간의 잔여 접점 방지)
        var postMultiCooldown: CFTimeInterval = 0.3
        /// 두 손가락 탭 → 오른쪽 클릭 (기본 꺼짐: 오작동 방지)
        var twoFingerTapRightClick = false
        var twoFingerTapMax: CFTimeInterval = 0.25
        /// 관성 감쇠 (60fps 기준 프레임당 남는 속도 비율)
        var friction: Double = 0.95
        var minMomentumSpeed: Double = 120 // pt/s
        /// 스크롤 출력 평활화 시간상수 (초). 패널 리포트 주기와 화면 주사율 차이로 생기는 끊김 제거
        var scrollSmoothing: Double = 0.024
        /// 스크롤 중 손가락 하나가 이 시간보다 짧게 사라지면 스크롤을 유지
        var contactDropGrace: CFTimeInterval = 0.08
        /// 중심이 이만큼 움직이고 간격 변화가 작으면(이동의 0.8배 미만) 바로 스크롤로 결정 (포인트)
        var scrollDecideTravel: CGFloat = 10
        /// 애매한 경우: 이동 또는 간격 변화가 이만큼 쌓이면 비율로 결정 (포인트)
        var decideDistance: CGFloat = 18
        /// 간격 변화가 중심 이동의 이 배수보다 크면 핀치 (한 손가락 고정 핀치 = 2배, 스크롤 중 흔들림 < 1배)
        var pinchOverTravel: CGFloat = 1.7
        /// 핀치 감도: 출력 배율 = (손가락 간격 비율)^pinchGain
        var pinchGain: Double = 0.5
        /// 핀치 출력 평활화 시간상수 (초)
        var zoomSmoothing: Double = 0.02
    }

    private struct Pending {
        let id: Int
        let start: CGPoint
        let time: CFAbsoluteTime
        var last: CGPoint
        var moved = false
        /// false면 두 손가락 직후의 접점 → 스크롤로만 전환 가능, 클릭/드래그 금지
        let armed: Bool
    }

    private enum State {
        case idle
        /// 첫 손가락이 닿았지만 아직 클릭/드래그/스크롤이 결정되지 않음
        case pending(Pending)
        /// 마우스 다운 후 드래그 중
        case pointer(id: Int, start: CGPoint, last: CGPoint, brokeSlop: Bool)
        case scroll(ScrollState)
        /// 제스처가 끝났으니 남은 손가락이 다 떨어질 때까지 클릭 없음
        case waitAllUp
    }

    private enum TwoFingerMode { case undecided, scroll, pinch }

    private struct ScrollState {
        var mode: TwoFingerMode = .undecided
        /// 시작 시 / 직전 프레임의 두 손가락 사이 거리
        var spread0: CGFloat = 0
        var spreadPrev: CGFloat = 0
        var ids: (Int, Int)
        var start: CGPoint
        var last: CGPoint
        var startTime: CFAbsoluteTime
        var maxTravel: CGFloat = 0
        var began = false
        /// 손가락 하나가 잠깐 사라진 시각 (패널이 한두 프레임 접점을 놓치는 경우 대비)
        var lostAt: CFAbsoluteTime?
        var samples: [(t: CFAbsoluteTime, dx: Double, dy: Double)] = []
        // 진단: 패널 리포트 간격 통계
        var lastFrame: CFAbsoluteTime?
        var gapSum = 0.0, gapMax = 0.0, gapN = 0
    }

    /// 손가락 이동량을 화면 주기에 맞춰 나눠 내보내는 출력 상태
    private struct ScrollOut {
        var at: CGPoint
        var pendX = 0.0, pendY = 0.0
        /// 손가락이 떨어짐 → 남은 양을 다 내보낸 뒤 ended + 관성
        var ending = false
        var momentumV: (x: Double, y: Double)?
        /// 손가락 하나가 잠깐 사라진 동안 현재 속도로 계속 흘려보냄 (멈칫 방지)
        var extrapolateV: (x: Double, y: Double)?
        /// 외삽으로 미리 내보낸 양 — 손가락이 돌아오면 실제 이동량에서 빼 준다
        var debtX = 0.0, debtY = 0.0
        var ticks = 0
    }

    var tuning = Tuning()
    private let out: EventOutput
    private var state: State = .idle
    private var pendingTimer: DispatchWorkItem?
    private let ticker = FrameTicker()
    private var scrollOut: ScrollOut?
    /// 핀치 출력: 아직 못 내보낸 배율(로그 스케일)
    private var zoomOut: (at: CGPoint, pendLog: Double, ending: Bool, total: Double)?
    private var momentum: (vx: Double, vy: Double, at: CGPoint, first: Bool)?
    private var lastMultiEnd: CFAbsoluteTime = 0

    var isActive: Bool {
        if case .idle = state { return false }
        return true
    }

    init(injector: EventOutput) {
        out = injector
        ticker.onTick = { [weak self] dt in self?.tick(dt) }
    }

    /// contacts: id 오름차순의 전역 화면 좌표. 비어 있으면 모든 손가락이 떨어짐.
    func process(_ contacts: [(id: Int, point: CGPoint)]) {
        let now = CFAbsoluteTimeGetCurrent()
        // 새 터치가 오면 진행 중인 관성/마무리 출력을 즉시 끝냄 (진행 중인 스크롤은 유지)
        if !contacts.isEmpty, momentum != nil || scrollOut?.ending == true || zoomOut?.ending == true {
            finishScrollOutput()
        }

        switch state {
        case .idle:
            if contacts.count >= 2 {
                beginScroll(contacts, now)
            } else if let c = contacts.first {
                let armed = now - lastMultiEnd > tuning.postMultiCooldown
                if armed { out.move(c.point) } // hover 상태를 먼저 만들어 줌
                state = .pending(Pending(id: c.id, start: c.point, time: now, last: c.point, armed: armed))
                schedulePendingCheck(after: tuning.secondFingerWindow)
            }

        case var .pending(p):
            if contacts.count >= 2 {
                // 두 번째 손가락 도착 → 아직 아무 버튼 이벤트도 안 보냈으므로 깨끗하게 스크롤로 전환
                cancelPendingCheck()
                beginScroll(contacts, now)
            } else if let c = contacts.first(where: { $0.id == p.id }) {
                p.last = c.point
                if dist(c.point, p.start) > tuning.tapSlop { p.moved = true }
                state = .pending(p)
                if p.moved && p.armed && now - p.time >= tuning.secondFingerWindow {
                    commitDrag(p)
                }
            } else {
                cancelPendingCheck()
                if p.armed {
                    if !p.moved {
                        // 탭: 흔들림과 무관하게 처음 닿은 위치에서 정확히 클릭
                        out.down(p.start)
                        out.up(p.start)
                    } else {
                        // 대기 시간 안에 끝난 짧은 한 손가락 스와이프
                        out.down(p.start)
                        out.drag(p.last)
                        out.up(p.last)
                    }
                }
                state = contacts.isEmpty ? .idle : .waitAllUp
            }

        case let .pointer(id, start, last, brokeSlop):
            if let c = contacts.first(where: { $0.id == id }) {
                let broke = brokeSlop || dist(c.point, start) > tuning.tapSlop
                // slop 안에서는 드래그 이벤트를 보내지 않음 → 버튼이 "끌기"로 오인하지 않음
                if broke && c.point != last { out.drag(c.point) }
                state = .pointer(id: id, start: start, last: broke ? c.point : last, brokeSlop: broke)
            } else {
                out.up(brokeSlop ? last : start)
                state = contacts.isEmpty ? .idle : .waitAllUp
            }

        case var .scroll(s):
            if contacts.count >= 2 {
                let pair = contacts.filter { $0.id == s.ids.0 || $0.id == s.ids.1 }
                if pair.count == 2 {
                    let c = centroid(pair.map(\.point))
                    let spread = dist(pair[0].point, pair[1].point)
                    s.maxTravel = max(s.maxTravel, dist(c, s.start))
                    if s.mode == .undecided {
                        let spreadChange = abs(spread - s.spread0)
                        let clearScroll = s.maxTravel > tuning.scrollDecideTravel && spreadChange < s.maxTravel * 0.8
                        let decide = clearScroll || max(spreadChange, s.maxTravel) > tuning.decideDistance
                        if decide && !clearScroll && spreadChange > s.maxTravel * tuning.pinchOverTravel {
                            // 거리 변화가 중심 이동보다 큼 → 핀치
                            s.mode = .pinch
                            s.spreadPrev = s.spread0 // 결정 전까지 벌어진 만큼도 배율에 포함
                            out.magnify(0, phase: .began, at: s.start)
                            zoomOut = (s.start, 0, false, 1)
                            ticker.start(near: s.start)
                            Diag.log("  ▶ 핀치 시작 at \(Diag.fmt(s.start))")
                        } else if decide {
                            s.mode = .scroll
                        }
                    }
                    if s.mode == .pinch {
                        if s.spreadPrev > 1, spread > 1 { zoomOut?.pendLog += tuning.pinchGain * Double(log(spread / s.spreadPrev)) }
                        s.spreadPrev = spread
                        s.lostAt = nil
                        state = .scroll(s)
                        return
                    }
                    s.spreadPrev = spread
                    if s.mode == .undecided {
                        s.lostAt = nil
                        state = .scroll(s) // 결정 전에는 기준점(s.last)을 그대로 둬서, 스크롤 결정 시 이동량이 누락되지 않게 함
                        return
                    }
                    let dx = Double(c.x - s.last.x), dy = Double(c.y - s.last.y)
                    if let lf = s.lastFrame {
                        s.gapSum += now - lf; s.gapMax = max(s.gapMax, now - lf); s.gapN += 1
                    }
                    s.lastFrame = now
                    if dx != 0 || dy != 0 {
                        if !s.began {
                            out.scroll(dx: 0, dy: 0, at: s.start, phase: .began)
                            scrollOut = ScrollOut(at: s.start)
                            ticker.start(near: s.start)
                        }
                        if var so = scrollOut {
                            so.pendX += dx - so.debtX
                            so.pendY += dy - so.debtY
                            so.debtX = 0; so.debtY = 0
                            so.extrapolateV = nil
                            scrollOut = so
                        }
                        s.began = true
                        s.samples.append((now, dx, dy))
                        s.samples.removeAll { now - $0.t > 0.15 }
                    }
                    s.last = c
                } else {
                    // 접점 ID가 바뀌어 돌아온 경우: 새 쌍으로 기준점만 옮김 (점프 없이)
                    let np = Array(contacts.prefix(2))
                    s.ids = (np[0].id, np[1].id)
                    s.last = centroid(np.map(\.point))
                    s.spreadPrev = dist(np[0].point, np[1].point)
                    scrollOut?.extrapolateV = nil
                    scrollOut?.debtX = 0; scrollOut?.debtY = 0
                }
                s.lostAt = nil
                state = .scroll(s)
            } else if contacts.isEmpty {
                endScroll(s, s.lostAt ?? now)
                state = .idle
            } else {
                let lost = s.lostAt ?? now
                if s.lostAt == nil, s.began, s.mode == .scroll { scrollOut?.extrapolateV = releaseVelocity(s, at: lost) }
                s.lostAt = lost
                if now - lost > tuning.contactDropGrace {
                    endScroll(s, lost)
                    state = .waitAllUp
                } else {
                    state = .scroll(s)
                }
            }

        case .waitAllUp:
            if contacts.count >= 2 {
                beginScroll(contacts, now) // 한 손가락을 남긴 채 다시 두 손가락 → 스크롤 재개
            } else if contacts.isEmpty {
                state = .idle
            }
        }
    }

    /// 장치 분리/기능 끄기 등으로 강제 종료
    func reset() {
        cancelPendingCheck()
        finishScrollOutput()
        out.forceUp()
        state = .idle
    }

    // MARK: Pending → drag / hold

    private func commitDrag(_ p: Pending) {
        cancelPendingCheck()
        out.down(p.start)
        out.drag(p.last)
        state = .pointer(id: p.id, start: p.start, last: p.last, brokeSlop: true)
    }

    private func schedulePendingCheck(after delay: CFTimeInterval) {
        cancelPendingCheck()
        let work = DispatchWorkItem { [weak self] in self?.evaluatePending() }
        pendingTimer = work
        DispatchQueue.main.asyncAfter(deadline: .now() + max(delay, 0.001), execute: work)
    }

    private func evaluatePending() {
        guard case let .pending(p) = state, p.armed else { return }
        let elapsed = CFAbsoluteTimeGetCurrent() - p.time
        if p.moved {
            commitDrag(p) // 두 번째 손가락이 오지 않았음 → 한 손가락 드래그 확정
        } else if elapsed >= tuning.holdDelay {
            out.down(p.start) // 가만히 길게 누름 → 그 자리에서 마우스 다운 (드래그/길게 누르기 메뉴)
            state = .pointer(id: p.id, start: p.start, last: p.start, brokeSlop: false)
        } else {
            schedulePendingCheck(after: tuning.holdDelay - elapsed)
        }
    }

    private func cancelPendingCheck() {
        pendingTimer?.cancel()
        pendingTimer = nil
    }

    // MARK: Scroll

    private func beginScroll(_ contacts: [(id: Int, point: CGPoint)], _ now: CFAbsoluteTime) {
        let pair = Array(contacts.prefix(2))
        let c = centroid(pair.map(\.point))
        out.move(c) // 스크롤/줌 대상 = 두 손가락 중심 아래의 뷰
        let spread = dist(pair[0].point, pair[1].point)
        state = .scroll(ScrollState(spread0: spread, spreadPrev: spread, ids: (pair[0].id, pair[1].id),
                                    start: c, last: c, startTime: now))
    }

    private func endScroll(_ s: ScrollState, _ now: CFAbsoluteTime) {
        lastMultiEnd = now
        if s.mode == .pinch {
            Diag.log(String(format: "  핀치 손가락 간격 %.0f → %.0fpt (×%.2f), %.1f초",
                            s.spread0, s.spreadPrev, s.spreadPrev / max(s.spread0, 1), now - s.startTime))
            zoomOut?.ending = true // 남은 배율을 마저 내보낸 뒤 ended
            return
        }
        if !s.began {
            if tuning.twoFingerTapRightClick,
               now - s.startTime < tuning.twoFingerTapMax && s.maxTravel < tuning.tapSlop {
                out.rightClick(s.start)
            }
            return
        }
        if s.gapN > 0 {
            Diag.log(String(format: "  스크롤 통계: 패널 리포트 %d개, 평균 간격 %.1fms, 최대 간격 %.1fms, 출력 %d프레임",
                            s.gapN + 1, s.gapSum / Double(s.gapN) * 1000, s.gapMax * 1000, scrollOut?.ticks ?? 0))
        }
        guard var so = scrollOut else { return }
        so.extrapolateV = nil
        if let v = releaseVelocity(s, at: now), hypot(v.x, v.y) > tuning.minMomentumSpeed {
            // 손을 떼는 즉시 같은 속도로 관성을 시작 (감속→재가속 '툭' 방지).
            // 아직 못 내보낸 양은 관성 초속도에 녹여 총 이동 거리를 유지한다.
            let glide = 1 / (60 * log(1 / tuning.friction)) // 초속도 1pt/s 당 관성 총 이동 거리
            let fx = so.pendX / glide, fy = so.pendY / glide
            let boost = hypot(fx, fy) < hypot(v.x, v.y) * 0.25 ? (fx, fy) : (0.0, 0.0)
            out.scroll(dx: 0, dy: 0, at: so.at, phase: .ended)
            scrollOut = nil
            momentum = (v.x + boost.0, v.y + boost.1, so.at, true)
            Diag.log(String(format: "  관성 초속도 %.0f pt/s", hypot(v.x, v.y)))
        } else {
            // 느리게 멈춘 경우: 남은 양만 부드럽게 흘려보낸 뒤 ended
            so.ending = true
            scrollOut = so
        }
    }

    /// 손 떼기 직전 속도. 떼는 순간의 흔들림(마지막 ~12ms)은 제외하고 약 100ms 구간의 평균.
    private func releaseVelocity(_ s: ScrollState, at end: CFAbsoluteTime) -> (x: Double, y: Double)? {
        var use = s.samples.filter { $0.t <= end - 0.012 && $0.t >= end - 0.11 }
        if use.count < 3 { use = s.samples.filter { end - $0.t <= 0.1 } }
        guard use.count >= 2, let first = use.first, let last = use.last else { return nil }
        // 마지막 샘플 이후 손가락이 멈춰 있었다면 그만큼 속도를 낮춤
        let span = max(last.t - first.t, 1.0 / 120)
        let idle = max(0, end - last.t - 0.02)
        let k = span / (span + idle)
        let dx = use.dropFirst().map(\.dx).reduce(0, +), dy = use.dropFirst().map(\.dy).reduce(0, +)
        return (dx / span * k, dy / span * k)
    }

    // MARK: Frame output

    private func tick(_ dt: Double) {
        if var z = zoomOut {
            let a = 1 - exp(-dt / tuning.zoomSmoothing)
            var e = z.pendLog * a
            if abs(z.pendLog) < 0.0005 { e = z.pendLog }
            if e != 0 {
                out.magnify(exp(e) - 1, phase: .changed, at: z.at)
                z.pendLog -= e
                z.total *= exp(e)
            }
            if z.ending && z.pendLog == 0 {
                out.magnify(0, phase: .ended, at: z.at)
                Diag.log(String(format: "  ▶ 핀치 끝 (배율 ×%.2f)", z.total))
                zoomOut = nil
            } else {
                zoomOut = z
            }
            return
        }
        if var so = scrollOut {
            so.ticks += 1
            if let v = so.extrapolateV {
                // 손가락 입력이 계속되는 것처럼 채워 넣음 → 출력 속도가 그대로 유지됨
                so.pendX += v.x * dt; so.pendY += v.y * dt
                so.debtX += v.x * dt; so.debtY += v.y * dt
            }
            let a = 1 - exp(-dt / tuning.scrollSmoothing)
            var ex = so.pendX * a, ey = so.pendY * a
            if abs(so.pendX) < 0.5 && abs(so.pendY) < 0.5 { ex = so.pendX; ey = so.pendY }
            if ex != 0 || ey != 0 {
                out.scroll(dx: ex, dy: ey, at: so.at, phase: .changed)
                so.pendX -= ex
                so.pendY -= ey
            }

            if so.ending && so.pendX == 0 && so.pendY == 0 {
                out.scroll(dx: 0, dy: 0, at: so.at, phase: .ended)
                scrollOut = nil
                if let v = so.momentumV { momentum = (v.x, v.y, so.at, true) }
            } else {
                scrollOut = so
            }
            return
        }
        if var m = momentum {
            let decay = pow(tuning.friction, dt * 60)
            m.vx *= decay
            m.vy *= decay
            if hypot(m.vx, m.vy) < 15 {
                stopMomentum()
                return
            }
            out.scroll(dx: m.vx * dt, dy: m.vy * dt, at: m.at, phase: .none, momentum: m.first ? .begin : .continue)
            m.first = false
            momentum = m
            return
        }
        ticker.stop()
    }

    /// 남은 출력을 즉시 마무리 (새 터치, 리셋)
    private func finishScrollOutput() {
        if let z = zoomOut {
            if z.pendLog != 0 { out.magnify(exp(z.pendLog) - 1, phase: .changed, at: z.at) }
            out.magnify(0, phase: .ended, at: z.at)
            zoomOut = nil
        }
        if let so = scrollOut {
            if so.pendX != 0 || so.pendY != 0 { out.scroll(dx: so.pendX, dy: so.pendY, at: so.at, phase: .changed) }
            out.scroll(dx: 0, dy: 0, at: so.at, phase: .ended)
            scrollOut = nil
        }
        stopMomentum()
    }

    private func stopMomentum() {
        if let m = momentum, !m.first {
            out.scroll(dx: 0, dy: 0, at: m.at, phase: .none, momentum: .end)
        }
        momentum = nil
    }

    // MARK: Math

    private func dist(_ a: CGPoint, _ b: CGPoint) -> CGFloat { hypot(a.x - b.x, a.y - b.y) }

    private func centroid(_ pts: [CGPoint]) -> CGPoint {
        CGPoint(x: pts.map(\.x).reduce(0, +) / CGFloat(pts.count),
                y: pts.map(\.y).reduce(0, +) / CGFloat(pts.count))
    }
}
