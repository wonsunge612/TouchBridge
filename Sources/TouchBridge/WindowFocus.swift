import AppKit
import ApplicationServices

/// 터치한 위치의 창을 키 창으로 만든다.
/// macOS는 비활성 앱/키가 아닌 창에 magnify(핀치) 이벤트를 보내지 않고, 첫 클릭은 창 활성화에만 쓰기 때문에
/// 다른 모니터를 보다가 바로 터치 제스처를 하면 첫 동작이 먹히지 않는다.
enum WindowFocus {
    struct Result {
        let pid: pid_t
        let appName: String
        /// 같은 앱 안에서 창만 바꾼 경우 (활성화 완료를 앱 전환으로 판단할 수 없음)
        let raisedOnly: Bool
    }

    /// - Returns: 포커스를 바꿨으면 그 앱 정보, 이미 키 창이거나 대상이 일반 창이 아니면 nil
    static func focus(at p: CGPoint) -> Result? {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return nil }
        let me = getpid()
        let frontPID = NSWorkspace.shared.frontmostApplication?.processIdentifier

        // 앞에서부터: 터치 지점을 덮는 첫 창
        var hit: (pid: pid_t, bounds: CGRect)?
        for w in list {
            guard let bd = w[kCGWindowBounds as String] as? NSDictionary,
                  let r = CGRect(dictionaryRepresentation: bd), r.contains(p) else { continue }
            if (w[kCGWindowAlpha as String] as? Double ?? 1) < 0.01 { continue }
            let layer = w[kCGWindowLayer as String] as? Int ?? 0
            // 메뉴/팝업/경고창(100 이상)이 열려 있으면 건드리지 않음 — 탭이 메뉴 선택이어야 하므로
            if layer >= 100 { return nil }
            // Dock의 전체 화면 창, 노치/HUD 오버레이, 떠 있는 패널 등은 투명하게 덮고 있을 수 있어 건너뜀
            if layer != 0 { continue }
            guard let pid = w[kCGWindowOwnerPID as String] as? pid_t, pid != me else { return nil }
            hit = (pid, r)
            break
        }
        guard let (pid, bounds) = hit, let app = NSRunningApplication(processIdentifier: pid) else { return nil }

        // 이미 앞 앱의 맨 앞 창이면 (= 키 창) 할 일 없음
        if pid == frontPID {
            let firstOfApp = list.first {
                ($0[kCGWindowOwnerPID as String] as? pid_t) == pid && ($0[kCGWindowLayer as String] as? Int ?? 0) == 0
            }
            if let bd = firstOfApp?[kCGWindowBounds as String] as? NSDictionary,
               let r = CGRect(dictionaryRepresentation: bd), r == bounds { return nil }
        }

        // 손쉬운 사용 API로 해당 창을 메인 창으로 올림
        let axApp = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(axApp, 0.1)
        var ref: CFTypeRef?
        if AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &ref) == .success,
           let windows = ref as? [AXUIElement],
           let win = windows.first(where: { frame(of: $0).map { near($0, bounds) } ?? false }) {
            AXUIElementSetAttributeValue(win, kAXMainAttribute as CFString, kCFBooleanTrue)
            AXUIElementPerformAction(win, kAXRaiseAction as CFString)
        }
        if pid != frontPID { app.activate(options: []) }
        return Result(pid: pid, appName: app.localizedName ?? "?", raisedOnly: pid == frontPID)
    }

    private static func frame(of w: AXUIElement) -> CGRect? {
        var pos: CFTypeRef?, size: CFTypeRef?
        guard AXUIElementCopyAttributeValue(w, kAXPositionAttribute as CFString, &pos) == .success,
              AXUIElementCopyAttributeValue(w, kAXSizeAttribute as CFString, &size) == .success else { return nil }
        var p = CGPoint.zero, s = CGSize.zero
        AXValueGetValue(pos as! AXValue, .cgPoint, &p)
        AXValueGetValue(size as! AXValue, .cgSize, &s)
        return CGRect(origin: p, size: s)
    }

    private static func near(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) < 3 && abs(a.minY - b.minY) < 3 && abs(a.width - b.width) < 3 && abs(a.height - b.height) < 3
    }
}
