import AppKit

/// 메뉴 막대 아이콘과 메뉴. 메뉴는 열릴 때마다 현재 상태로 다시 그린다.
final class StatusMenuController: NSObject, NSMenuDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()
    private let controller: TouchController
    private let calibration = CalibrationWindowController()

    init(controller: TouchController) {
        self.controller = controller
        super.init()
        menu.delegate = self
        menu.autoenablesItems = false
        statusItem.menu = menu
        updateIcon()
        for name in [Notification.Name.touchDevicesDidChange, .displaysDidChange] {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.updateIcon()
            }
        }
    }

    private func updateIcon() {
        guard let button = statusItem.button else { return }
        let connected = !controller.devices.panels.isEmpty
        let symbol = controller.enabled ? (connected ? "hand.tap.fill" : "hand.tap") : "hand.raised.slash"
        let img = NSImage(systemSymbolName: symbol, accessibilityDescription: "TouchBridge")
        img?.isTemplate = true
        button.image = img
        button.appearsDisabled = !controller.enabled
        button.toolTip = "TouchBridge — " + (connected ? "터치 장치 연결됨" : "터치 장치 없음")
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        // 장치 상태
        let panels = controller.devices.panels.values.sorted { $0.name < $1.name }
        if panels.isEmpty {
            menu.addItem(disabled(controller.enabled ? "연결된 터치 장치 없음" : "터치 기능 꺼짐"))
        } else {
            for p in panels {
                let mode = p.allSeized ? "독점 모드" : (controller.injector.suppressionActive ? "호환 모드" : "호환 모드 ⚠︎")
                menu.addItem(disabled("● \(p.name) — \(mode)"))
            }
        }
        menu.addItem(.separator())

        // 켜기/끄기
        let toggle = item(controller.enabled ? "터치 기능 끄기" : "터치 기능 켜기", #selector(toggleTouch), key: "t")
        toggle.state = controller.enabled ? .on : .off
        menu.addItem(toggle)
        menu.addItem(.separator())

        // 대상 모니터
        menu.addItem(disabled("대상 모니터"))
        let target = controller.targetDisplay
        if target == nil {
            menu.addItem(disabled("   ⚠︎ 선택한 모니터가 연결되어 있지 않음 — 터치 무시 중"))
        }
        for d in controller.displays.displays {
            var title = "\(d.name)  \(Int(d.bounds.width))×\(Int(d.bounds.height))"
            if d.isMain { title += "  (주 모니터)" }
            if d.rotation != 0 { title += "  ↻\(d.rotation)°" }
            let it = item(title, #selector(selectDisplay(_:)))
            it.representedObject = d.key
            it.state = d.key == target?.key ? .on : .off
            it.indentationLevel = 1
            menu.addItem(it)
        }
        menu.addItem(.separator())

        // 핀치 줌 감도
        let pinch = NSMenuItem(title: "핀치 줌 감도", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        for (title, gain) in [("낮게", 0.35), ("보통", 0.5), ("높게", 0.75), ("손가락과 1:1", 1.0)] {
            let it = item(title, #selector(selectPinchGain(_:)))
            it.representedObject = gain
            it.state = abs(controller.pinchGain - gain) < 0.001 ? .on : .off
            sub.addItem(it)
        }
        pinch.submenu = sub
        menu.addItem(pinch)
        menu.addItem(.separator())

        // 보정
        let cal = item("4포인트 터치 보정…", #selector(openCalibration), key: "k")
        cal.isEnabled = target != nil
        menu.addItem(cal)
        let reset = item(controller.isTargetCalibrated ? "보정 초기화" : "보정 초기화 (보정 안 됨)", #selector(resetCalibration))
        reset.isEnabled = controller.isTargetCalibrated
        menu.addItem(reset)

        // 권한 안내
        var permItems: [NSMenuItem] = []
        if !Permissions.inputMonitoring {
            permItems.append(item("⚠︎ 입력 모니터링 권한 허용…", #selector(openInputMonitoring)))
        }
        if !Permissions.accessibility || !Permissions.postEvents {
            permItems.append(item("⚠︎ 손쉬운 사용 권한 허용…", #selector(openAccessibility)))
        }
        if !permItems.isEmpty {
            menu.addItem(.separator())
            permItems.forEach(menu.addItem)
        }

        // 로그인 시 자동 실행
        menu.addItem(.separator())
        if LoginItem.needsApproval {
            menu.addItem(item("로그인 시 자동 실행 — 시스템 설정에서 허용 필요…", #selector(openLoginItems)))
        } else {
            let login = item("로그인 시 자동 실행", #selector(toggleLoginItem))
            login.state = LoginItem.isEnabled ? .on : .off
            menu.addItem(login)
            if !LoginItem.isInApplications {
                menu.addItem(disabled("   응용 프로그램 폴더로 옮긴 뒤 켜는 것을 권장"))
            }
        }

        menu.addItem(.separator())
        menu.addItem(item("종료", #selector(quit), key: "q"))
    }

    // MARK: Actions

    @objc private func toggleTouch() {
        controller.enabled.toggle()
        updateIcon()
    }

    @objc private func selectDisplay(_ sender: NSMenuItem) {
        guard let key = sender.representedObject as? String,
              let d = controller.displays.display(forKey: key) else { return }
        controller.selectTarget(d)
    }

    @objc private func selectPinchGain(_ sender: NSMenuItem) {
        if let g = sender.representedObject as? Double { controller.pinchGain = g }
    }

    @objc private func toggleLoginItem() {
        do {
            try LoginItem.set(!LoginItem.isEnabled)
            if LoginItem.needsApproval { LoginItem.openSettings() }
        } catch {
            Diag.log("로그인 항목 변경 실패: \(error.localizedDescription)")
            let alert = NSAlert()
            alert.messageText = "로그인 시 자동 실행을 바꾸지 못했습니다"
            alert.informativeText = error.localizedDescription
            alert.addButton(withTitle: "시스템 설정 열기")
            alert.addButton(withTitle: "닫기")
            NSApp.activate(ignoringOtherApps: true)
            if alert.runModal() == .alertFirstButtonReturn { LoginItem.openSettings() }
        }
    }

    @objc private func openLoginItems() { LoginItem.openSettings() }

    @objc private func openCalibration() { calibration.show(controller: controller) }
    @objc private func resetCalibration() { controller.resetCalibration() }
    @objc private func openInputMonitoring() { Permissions.openSettings("Privacy_ListenEvent") }
    @objc private func openAccessibility() { Permissions.openSettings("Privacy_Accessibility") }
    @objc private func quit() { NSApp.terminate(nil) }

    // MARK: Helpers

    private func item(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let it = NSMenuItem(title: title, action: action, keyEquivalent: key)
        it.target = self
        return it
    }

    private func disabled(_ title: String) -> NSMenuItem {
        let it = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        it.isEnabled = false
        return it
    }
}
