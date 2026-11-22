import AppKit
import Sparkle

/// Sparkle 자동 업데이트.
/// Info.plist 의 SUFeedURL(최신 GitHub 릴리스의 appcast.xml)을 하루 한 번 확인하고,
/// 새 버전이 있으면 변경 내용과 함께 설치 여부를 묻는다. 업데이트 파일은 EdDSA 서명이 맞아야 설치된다.
///
/// 시험용 환경 변수
///   TOUCHBRIDGE_FEED_URL=<url>   다른 appcast 사용 (로컬 서버 등)
///   TOUCHBRIDGE_UPDATE_TEST=1    실행 직후 백그라운드 확인 → 자동 다운로드 → 종료 시 설치 (UI 없이 전체 흐름 검증)
final class Updater: NSObject, SPUUpdaterDelegate {
    private(set) var controller: SPUStandardUpdaterController!
    private let env = ProcessInfo.processInfo.environment

    override init() {
        super.init()
        controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: self, userDriverDelegate: nil)
        do {
            try controller.updater.start()
        } catch {
            Diag.log("업데이트 기능 시작 실패: \(error.localizedDescription)")
        }
        let u = controller.updater
        Diag.log("업데이트: 피드 \(u.feedURL?.absoluteString ?? "없음"), 자동 확인=\(u.automaticallyChecksForUpdates)")

        if env["TOUCHBRIDGE_UPDATE_TEST"] == "1" {
            u.automaticallyDownloadsUpdates = true
            u.checkForUpdatesInBackground()
        }
    }

    var updater: SPUUpdater { controller.updater }
    var canCheck: Bool { controller.updater.canCheckForUpdates }

    var automaticallyChecks: Bool {
        get { updater.automaticallyChecksForUpdates }
        set { updater.automaticallyChecksForUpdates = newValue }
    }

    @objc func checkForUpdates(_ sender: Any?) {
        NSApp.activate(ignoringOtherApps: true) // 메뉴 막대 앱이라 창이 뒤에 뜨지 않게
        controller.checkForUpdates(sender)
    }

    static var currentVersion: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let short = info["CFBundleShortVersionString"] as? String ?? "?"
        let build = info["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }

    // MARK: SPUUpdaterDelegate

    func feedURLString(for updater: SPUUpdater) -> String? { env["TOUCHBRIDGE_FEED_URL"] }

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        Diag.log("업데이트 발견: \(item.displayVersionString) (\(item.versionString))")
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
        Diag.log("업데이트 없음: 최신 버전 사용 중 (\(Self.currentVersion))")
    }

    func updater(_ updater: SPUUpdater, didDownloadUpdate item: SUAppcastItem) {
        Diag.log("업데이트 다운로드 완료: \(item.displayVersionString)")
    }

    func updater(_ updater: SPUUpdater, willInstallUpdate item: SUAppcastItem) {
        Diag.log("업데이트 설치 시작: \(item.displayVersionString)")
    }

    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        Diag.log("업데이트 중단: \(error.localizedDescription)")
    }
}
