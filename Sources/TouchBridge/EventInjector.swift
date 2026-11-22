import AppKit
import CoreGraphics

/// 저수준 CGEvent 합성 + (독점 실패 시) CGEventTap 기반 시스템 이벤트 억제.
final class EventInjector: EventOutput {
    /// 우리가 만든 이벤트 표식 — EventTap에서 통과시킨다.
    static let syntheticTag: Int64 = 0x5442_5247 // "TBRG"

    private let source = CGEventSource(stateID: .hidSystemState)
    private(set) var isDown = false
    private var lastDownTime: CFAbsoluteTime = 0
    private var lastDownPoint = CGPoint(x: -1000, y: -1000)
    private var clickCount: Int64 = 1

    /// 제스처 엔진이 터치를 처리 중인지 (호환 모드 필터에서 사용)
    var touchBusy: () -> Bool = { false }

    // MARK: Activation gate

    /// 터치한 창을 활성화하는 동안 출력을 잠시 모아 두었다가, 활성화가 끝나면 순서대로 내보낸다.
    private var gate: (pid: pid_t, minTime: CFAbsoluteTime, deadline: CFAbsoluteTime)?
    private var queued: [() -> Void] = []

    func holdUntilActive(pid: pid_t, raisedOnly: Bool) {
        let now = CFAbsoluteTimeGetCurrent()
        // 같은 앱 안의 창 전환은 앱 전환 알림이 없으므로 최소 대기 시간만 둠
        gate = (pid, now + (raisedOnly ? 0.04 : 0.0), now + 0.15)
        pollGate()
    }

    private func pollGate() {
        guard let g = gate else { return }
        let now = CFAbsoluteTimeGetCurrent()
        let active = NSWorkspace.shared.frontmostApplication?.processIdentifier == g.pid
        if (active && now >= g.minTime) || now >= g.deadline {
            gate = nil
            let q = queued
            queued.removeAll()
            Diag.log(String(format: "  창 활성화 %@ (%.0fms, 대기 이벤트 %d개)", active ? "완료" : "시간 초과",
                            (now - (g.deadline - 0.15)) * 1000, q.count))
            q.forEach { $0() }
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.004) { [weak self] in self?.pollGate() }
    }

    private func emit(_ f: @escaping () -> Void) {
        if gate != nil { queued.append(f) } else { f() }
    }

    // MARK: Mouse

    func move(_ p: CGPoint) {
        emit { [self] in postMouse(.mouseMoved, p, .left) }
    }

    func down(_ p: CGPoint) {
        emit { [self] in
            guard !isDown else { return }
            let now = CFAbsoluteTimeGetCurrent()
            let near = hypot(p.x - lastDownPoint.x, p.y - lastDownPoint.y) < 24
            clickCount = (now - lastDownTime < NSEvent.doubleClickInterval && near) ? clickCount + 1 : 1
            lastDownTime = now
            lastDownPoint = p
            postMouse(.leftMouseDown, p, .left)
            isDown = true
            Diag.log("  ▶ 마우스 다운 \(Diag.fmt(p)) click=\(clickCount)")
        }
    }

    func drag(_ p: CGPoint) {
        emit { [self] in
            guard isDown else { return }
            postMouse(.leftMouseDragged, p, .left)
        }
    }

    func up(_ p: CGPoint) {
        emit { [self] in
            guard isDown else { return }
            postMouse(.leftMouseUp, p, .left)
            isDown = false
            Diag.log("  ▶ 마우스 업 \(Diag.fmt(p))")
        }
    }

    func rightClick(_ p: CGPoint) {
        emit { [self] in
            Diag.log("  ▶ 오른쪽 클릭 \(Diag.fmt(p))")
            clickCount = 1
            postMouse(.mouseMoved, p, .left)
            postMouse(.rightMouseDown, p, .right)
            postMouse(.rightMouseUp, p, .right)
        }
    }

    func forceUp(at p: CGPoint?) {
        if isDown { up(p ?? lastDownPoint) }
    }

    private func postMouse(_ type: CGEventType, _ p: CGPoint, _ button: CGMouseButton) {
        guard let e = CGEvent(mouseEventSource: source, mouseType: type,
                              mouseCursorPosition: p, mouseButton: button) else { return }
        e.setIntegerValueField(.eventSourceUserData, value: Self.syntheticTag)
        if type != .mouseMoved {
            e.setIntegerValueField(.mouseEventClickState, value: clickCount)
            // 실제 마우스와 같게: 눌림/드래그 1.0, 뗌 0.0 (일부 컨트롤은 압력 0의 클릭을 무시)
            let pressed = type == .leftMouseDown || type == .leftMouseDragged || type == .rightMouseDown
            e.setDoubleValueField(.mouseEventPressure, value: pressed ? 1.0 : 0.0)
        }
        e.post(tap: .cghidEventTap)
    }

    // MARK: Scroll (트랙패드형 연속 스크롤)

    private var remX = 0.0, remY = 0.0

    /// dx/dy: 화면 포인트 단위 콘텐츠 이동량 (양수 = 콘텐츠가 오른쪽/아래로 이동)
    func scroll(dx: Double, dy: Double, at p: CGPoint, phase: ScrollPhase, momentum: MomentumPhase) {
        emit { [self] in
            if phase == .began || phase == .ended || momentum == .begin || momentum == .end {
                Diag.log("  ▶ 스크롤 \(phase == .began ? "시작" : phase == .ended ? "끝" : momentum == .begin ? "관성 시작" : "관성 끝") at \(Diag.fmt(p))")
            }
            let fx = dx + remX, fy = dy + remY
            let ix = fx.rounded(.towardZero), iy = fy.rounded(.towardZero)
            remX = fx - ix
            remY = fy - iy
            if phase == .ended || phase == .cancelled || momentum == .end { remX = 0; remY = 0 }
    
            guard let e = CGEvent(scrollWheelEvent2Source: source, units: .pixel, wheelCount: 2,
                                  wheel1: Int32(iy), wheel2: Int32(ix), wheel3: 0) else { return }
            e.location = p
            e.setIntegerValueField(.eventSourceUserData, value: Self.syntheticTag)
            e.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
            e.setIntegerValueField(.scrollWheelEventPointDeltaAxis1, value: Int64(iy))
            e.setIntegerValueField(.scrollWheelEventPointDeltaAxis2, value: Int64(ix))
            e.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: iy)
            e.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2, value: ix)
            e.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase.rawValue)
            e.setIntegerValueField(.scrollWheelEventMomentumPhase, value: momentum.rawValue)
            e.post(tap: .cghidEventTap)
        }
    }

    // MARK: Magnify (핀치 줌)

    /// 트랙패드 핀치와 같은 magnify 제스처 이벤트.
    /// 공개 API가 없어 CGEvent 비공개 필드를 사용한다:
    ///   type 29 = NSEventTypeGesture, field 110 = 제스처 종류(8: zoom),
    ///   field 113 = magnification, field 132 = phase (1 began / 2 changed / 4 ended)
    func magnify(_ m: Double, phase: ScrollPhase, at p: CGPoint) {
        emit { [self] in
            guard let e = CGEvent(source: source),
                  let fKind = CGEventField(rawValue: 110),
                  let fMag = CGEventField(rawValue: 113),
                  let fPhase = CGEventField(rawValue: 132) else { return }
            e.type = unsafeBitCast(UInt32(29), to: CGEventType.self)
            e.location = p
            e.setIntegerValueField(fKind, value: 8)
            e.setIntegerValueField(fPhase, value: phase.rawValue)
            e.setDoubleValueField(fMag, value: m)
            e.setIntegerValueField(.eventSourceUserData, value: Self.syntheticTag)
            e.post(tap: .cghidEventTap)
        }
    }

    // MARK: Fallback suppression (호환 모드)

    private var tap: CFMachPort?
    private var tapSource: CFRunLoopSource?
    private var lastTouchActivity: CFAbsoluteTime = 0
    /// 판정 보류 중인 버튼 이벤트 (HID 콜백보다 시스템 이벤트가 먼저 도착하는 경쟁 대비)
    private var pending: [(event: CGEvent, time: CFAbsoluteTime)] = []
    private var flushScheduled = false

    private let touchWindow: CFAbsoluteTime = 0.08
    private let holdDelay: CFAbsoluteTime = 0.035

    var suppressionActive: Bool { tap != nil }

    func noteTouchActivity() { lastTouchActivity = CFAbsoluteTimeGetCurrent() }

    /// - Returns: 요청 상태가 실제로 적용되었는지 (탭 생성에는 손쉬운 사용 권한 필요)
    @discardableResult
    func setSuppression(_ on: Bool) -> Bool {
        if on == (tap != nil) { return true }
        if !on {
            if let t = tap { CGEvent.tapEnable(tap: t, enable: false) }
            if let s = tapSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), s, .commonModes) }
            tap = nil
            tapSource = nil
            pending.forEach { repost($0.event) }
            pending.removeAll()
            return true
        }
        let types: [CGEventType] = [.mouseMoved, .leftMouseDown, .leftMouseUp, .leftMouseDragged,
                                    .rightMouseDown, .rightMouseUp, .rightMouseDragged]
        let mask = types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << CGEventMask($1.rawValue)) }
        guard let t = CGEvent.tapCreate(
            tap: .cghidEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, ctx in
                guard let ctx else { return Unmanaged.passUnretained(event) }
                return Unmanaged<EventInjector>.fromOpaque(ctx).takeUnretainedValue().filter(type, event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { return false }
        tap = t
        tapSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, t, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), tapSource, .commonModes)
        CGEvent.tapEnable(tap: t, enable: true)
        return true
    }

    private func filter(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let t = tap { CGEvent.tapEnable(tap: t, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        if event.getIntegerValueField(.eventSourceUserData) == Self.syntheticTag {
            return Unmanaged.passUnretained(event)
        }
        let now = CFAbsoluteTimeGetCurrent()
        if touchBusy() || now - lastTouchActivity < touchWindow { return nil } // 터치 장치발 → 삼킴

        switch type {
        case .mouseMoved:
            return Unmanaged.passUnretained(event)
        case .leftMouseDown, .rightMouseDown:
            hold(event, now) // 직후 터치 리포트가 오면 터치발로 보고 폐기
            return nil
        default:
            if pending.isEmpty { return Unmanaged.passUnretained(event) }
            hold(event, now) // 순서 보존
            return nil
        }
    }

    private func hold(_ event: CGEvent, _ now: CFAbsoluteTime) {
        guard let copy = event.copy() else { return }
        pending.append((copy, now))
        scheduleFlush()
    }

    private func scheduleFlush() {
        guard !flushScheduled else { return }
        flushScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + holdDelay) { [weak self] in
            guard let self else { return }
            self.flushScheduled = false
            let now = CFAbsoluteTimeGetCurrent()
            while let head = self.pending.first, now - head.time >= self.holdDelay {
                self.pending.removeFirst()
                if self.lastTouchActivity >= head.time - self.touchWindow { continue } // 터치발
                self.repost(head.event)
            }
            if !self.pending.isEmpty { self.scheduleFlush() }
        }
    }

    private func repost(_ e: CGEvent) {
        e.setIntegerValueField(.eventSourceUserData, value: Self.syntheticTag)
        e.post(tap: .cghidEventTap)
    }
}
