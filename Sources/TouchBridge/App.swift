import AppKit

@main
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controller: TouchController!
    private var statusMenu: StatusMenuController!
    private var updater: Updater!
    private let monitorKeeper = MonitorKeeper()

    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory) // Dock 아이콘 없이 메뉴 막대에만 표시
        app.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        controller = TouchController()
        updater = Updater()
        statusMenu = StatusMenuController(controller: controller, updater: updater, monitorKeeper: monitorKeeper)
        controller.start()
        monitorKeeper.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        controller.shutdown() // 눌린 상태 해제 + 장치 독점 해제
    }
}
