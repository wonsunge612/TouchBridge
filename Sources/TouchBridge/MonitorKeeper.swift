import AppKit

extension Notification.Name {
    static let monitorSettingsDidChange = Notification.Name("TouchBridge.monitorSettingsDidChange")
}

/// 휴대용 모니터는 전원이 다시 들어오면 밝기 등이 초기화되는 경우가 많다.
/// 외장 모니터의 밝기·명암·음량을 DDC/CI 로 기억해 두었다가, 모니터가 연결되거나(전원 켜짐)
/// DDC 응답이 끊겼다 돌아오면 그 값으로 되돌린다. 모니터 버튼(OSD)으로 바꾼 값은 몇 초 안에 새로 기억한다.
///
/// 스레드: status/present 는 메인, DDC 통신과 그 상태는 DDC.queue.
final class MonitorKeeper {
    struct Control { let code: UInt8; let name: String }
    static let controls = [Control(code: 0x10, name: "밝기"), Control(code: 0x12, name: "명암"), Control(code: 0x62, name: "음량")]

    struct Status {
        var name: String
        /// nil = 확인 중, false = DDC 미지원
        var supported: Bool?
        var values: [UInt8: Int] = [:]
        var maxes: [UInt8: Int] = [:]
    }

    /// 메인 스레드: 연결된 외장 모니터(DisplayInfo.key) → 상태 (메뉴 표시용)
    private(set) var status: [String: Status] = [:]
    private var present: [String: CGDirectDisplayID] = [:]

    private let settings = AppSettings.shared
    private let displays = DisplayManager.shared
    private let pollInterval: TimeInterval = 4

    // ---- DDC.queue 전용 ----
    private var qPresent: [String: CGDirectDisplayID] = [:]
    private var channels: [CGDirectDisplayID: DDCChannel] = [:]
    private var restoring: Set<String> = []
    private var unresponsive: [String: Int] = [:]
    private var lastWrite: [String: CFAbsoluteTime] = [:]
    private var timer: DispatchSourceTimer?

    var keepEnabled: Bool {
        get { settings.keepMonitorSettings }
        set {
            settings.keepMonitorSettings = newValue
            Diag.log("모니터 설정 유지 → \(newValue ? "켜짐" : "꺼짐")")
            if newValue { present.forEach { k, id in scheduleRestore(k, id, after: 0.2) } }
        }
    }

    func start() {
        guard DDC.isAvailable else {
            Diag.log("모니터 설정 유지: 이 맥에서는 DDC/CI를 쓸 수 없음 (Apple Silicon 필요)")
            return
        }
        NotificationCenter.default.addObserver(forName: .displaysDidChange, object: nil, queue: .main) { [weak self] _ in
            self?.syncDisplays(initial: false)
        }
        syncDisplays(initial: true)
        let t = DispatchSource.makeTimerSource(queue: DDC.queue)
        t.schedule(deadline: .now() + pollInterval, repeating: pollInterval, leeway: .milliseconds(500))
        t.setEventHandler { [weak self] in self?.poll() }
        t.resume()
        timer = t
    }

    // 슬라이더 값: 메인에서 넣고 DDC 큐에서 꺼냄. 끄는 동안 쌓이지 않도록 마지막 값만 남긴다.
    private let pendingLock = NSLock()
    private var pending: [String: [UInt8: Int]] = [:]
    private var flushScheduled: Set<String> = []

    /// 메뉴 슬라이더에서 값 변경 (메인). 모니터는 0.5초보다 자주 쓰면 무시하므로 마지막 값만 보낸다.
    func set(_ value: Int, code: UInt8, for key: String) {
        status[key]?.values[code] = value
        pendingLock.lock()
        pending[key, default: [:]][code] = value
        let schedule = flushScheduled.insert(key).inserted
        pendingLock.unlock()
        if schedule { DDC.queue.async { [self] in flushWrites(key) } }
    }

    private func hasPending(_ key: String) -> Bool {
        pendingLock.lock(); defer { pendingLock.unlock() }
        return !(pending[key]?.isEmpty ?? true) || flushScheduled.contains(key)
    }

    // MARK: 연결 변화 (메인)

    private func syncDisplays(initial: Bool) {
        let now = Dictionary(displays.displays.filter { !$0.isBuiltin }.map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })
        for (key, d) in now where present[key] == nil || present[key] != d.id {
            present[key] = d.id
            status[key] = Status(name: d.name, supported: nil)
            Diag.log("모니터 설정: \(d.name) 연결됨 — \(initial ? 1 : 2.5)초 뒤 확인")
            // 막 켜진 모니터는 부팅에 시간이 걸려 바로 DDC에 응답하지 않음
            scheduleRestore(key, d.id, after: initial ? 1 : 2.5)
        }
        for key in present.keys where now[key] == nil {
            present[key] = nil
            status[key] = nil
        }
        let snapshot = present
        DDC.queue.async { [self] in
            qPresent = snapshot
            channels = channels.filter { snapshot.values.contains($0.key) }
        }
        NotificationCenter.default.post(name: .monitorSettingsDidChange, object: self)
    }

    private func scheduleRestore(_ key: String, _ id: CGDirectDisplayID, after delay: TimeInterval) {
        DDC.queue.asyncAfter(deadline: .now() + delay) { [self] in restore(key, id, reason: "연결") }
    }

    // MARK: DDC.queue

    private func channel(for id: CGDirectDisplayID, waitUpTo seconds: Int) -> DDCChannel? {
        for i in 0...seconds {
            if let ch = channels[id] { return ch }
            channels = DDC.channels()
            if let ch = channels[id] { return ch }
            if i < seconds { sleep(1) }
        }
        return nil
    }

    private func readAll(_ ch: DDCChannel, attempts: Int = 4) -> (values: [UInt8: Int], maxes: [UInt8: Int]) {
        var v: [UInt8: Int] = [:], m: [UInt8: Int] = [:]
        for c in Self.controls { if let r = ch.read(c.code, attempts: attempts) { v[c.code] = r.value; m[c.code] = r.max } }
        return (v, m)
    }

    /// 기억한 값으로 되돌리기. 처음 보는 모니터면 현재 값을 기억만 한다.
    private func restore(_ key: String, _ id: CGDirectDisplayID, reason: String) {
        guard qPresent[key] == id || qPresent.isEmpty, !restoring.contains(key) else { return }
        restoring.insert(key)
        defer { restoring.remove(key) }
        let name = DisplayManager.screen(for: id)?.localizedName ?? key

        guard let ch = channel(for: id, waitUpTo: 5) else {
            Diag.log("모니터 설정: \(name) DDC 통로를 찾지 못함 — 지원하지 않는 연결 방식")
            publish(key) { $0.supported = false }
            return
        }
        // 막 켜진 모니터는 몇 초 동안 응답이 없을 수 있음
        var cur = readAll(ch)
        for _ in 0..<3 where cur.values.isEmpty {
            sleep(2)
            cur = readAll(ch)
        }
        guard !cur.values.isEmpty else {
            Diag.log("모니터 설정: \(name) DDC 응답 없음 — 이 모니터는 지원하지 않음")
            publish(key) { $0.supported = false }
            return
        }
        unresponsive[key] = 0

        var saved = settings.monitorValues(for: key)
        if saved.isEmpty {
            for (c, v) in cur.values { settings.setMonitorValue(v, code: c, for: key) }
            Diag.log("모니터 설정: \(name) 처음 연결 — 현재 값 기억 \(describe(cur.values))")
            publish(key) { $0.supported = true; $0.values = cur.values; $0.maxes = cur.maxes }
            return
        }
        // 기억 안 된 항목은 지금 값을 기억
        for (c, v) in cur.values where saved[c] == nil { settings.setMonitorValue(v, code: c, for: key); saved[c] = v }

        let diffs = Self.controls.filter { c in cur.values[c.code].map { $0 != saved[c.code] } ?? false }
        guard settings.keepMonitorSettings, !diffs.isEmpty else {
            if !diffs.isEmpty { Diag.log("모니터 설정: \(name) 값이 다르지만 '유지'가 꺼져 있어 그대로 둠") }
            publish(key) { $0.supported = true; $0.values = cur.values; $0.maxes = cur.maxes }
            return
        }

        let change = diffs.map { "\($0.name) \(cur.values[$0.code]!)→\(saved[$0.code]!)" }.joined(separator: ", ")
        Diag.log("모니터 설정: \(name) \(reason) — 복원 \(change)")
        var final = cur.values
        for attempt in 1...3 {
            let todo = Self.controls.filter { final[$0.code] != nil && final[$0.code] != saved[$0.code] }
            if todo.isEmpty { break }
            for c in todo { ch.write(c.code, saved[c.code]!) }
            lastWrite[key] = CFAbsoluteTimeGetCurrent()
            for c in todo { if let r = ch.read(c.code) { final[c.code] = r.value } }   // 쓰기 후 1.5초 지나야 읽힘
            let still = todo.filter { final[$0.code] != saved[$0.code] }
            if still.isEmpty {
                Diag.log("  ▶ 복원 확인 완료 (\(attempt)회)")
            } else if attempt == 3 {
                Diag.log("  ▶ 복원 실패: \(still.map(\.name).joined(separator: ", "))")
            }
        }
        publish(key) { $0.supported = true; $0.values = final; $0.maxes = cur.maxes }
    }

    /// 주기적으로 읽어서: 모니터 버튼으로 바꾼 값은 기억하고, 응답이 끊겼다 돌아오면(전원 껐다 켬) 복원
    private func poll() {
        for (key, id) in qPresent {
            guard !restoring.contains(key), !hasPending(key),
                  CFAbsoluteTimeGetCurrent() - (lastWrite[key] ?? 0) > 3,
                  let ch = channels[id] else { continue }
            let cur = readAll(ch, attempts: 2)
            if cur.values.isEmpty {
                unresponsive[key, default: 0] += 1
                continue
            }
            if unresponsive[key, default: 0] >= 2 {
                unresponsive[key] = 0
                restore(key, id, reason: "응답 재개(전원 다시 켜짐)")
                continue
            }
            unresponsive[key] = 0
            let saved = settings.monitorValues(for: key)
            var changed: [String] = []
            for c in Self.controls {
                guard let v = cur.values[c.code], v != saved[c.code] else { continue }
                settings.setMonitorValue(v, code: c.code, for: key)
                changed.append("\(c.name) \(saved[c.code].map(String.init) ?? "-")→\(v)")
            }
            if !changed.isEmpty { Diag.log("모니터 설정: 모니터에서 바꾼 값 기억 — \(changed.joined(separator: ", "))") }
            publish(key) { s in s.supported = true; for (c, v) in cur.values { s.values[c] = v }; for (c, m) in cur.maxes { s.maxes[c] = m } }
        }
    }

    private func flushWrites(_ key: String) {
        pendingLock.lock()
        let todo = pending[key] ?? [:]
        pending[key] = nil
        flushScheduled.remove(key)
        pendingLock.unlock()
        guard !todo.isEmpty else { return }
        for (c, v) in todo { settings.setMonitorValue(v, code: c, for: key) }
        guard let id = qPresent[key], let ch = channel(for: id, waitUpTo: 0) else { return }
        for (c, v) in todo.sorted(by: { $0.key < $1.key }) { ch.write(c, v) }   // 직전 쓰기 후 0.6초가 지날 때까지 기다림
        lastWrite[key] = CFAbsoluteTimeGetCurrent()
        Diag.log("모니터 설정: 메뉴에서 변경 — \(describe(todo))")
    }

    private func publish(_ key: String, _ update: @escaping (inout Status) -> Void) {
        DispatchQueue.main.async { [self] in
            guard status[key] != nil else { return }
            update(&status[key]!)
            NotificationCenter.default.post(name: .monitorSettingsDidChange, object: self)
        }
    }

    private func describe(_ v: [UInt8: Int]) -> String {
        Self.controls.compactMap { c in v[c.code].map { "\(c.name) \($0)" } }.joined(separator: ", ")
    }
}
