import Foundation
import ServiceManagement

/// 로그인 시 자동 실행 (macOS 13+ SMAppService). 시스템 설정 › 일반 › 로그인 항목에 표시된다.
enum LoginItem {
    static var status: SMAppService.Status { SMAppService.mainApp.status }
    static var isEnabled: Bool { status == .enabled }
    /// 등록은 됐지만 사용자가 시스템 설정에서 꺼 두었거나 승인이 필요한 상태
    static var needsApproval: Bool { status == .requiresApproval }

    /// 앱이 /Applications 밖에 있으면 로그인 항목이 그 경로를 가리켜, 앱을 옮기면 끊긴다.
    static var isInApplications: Bool {
        let path = Bundle.main.bundlePath
        return path.hasPrefix("/Applications/") || path.hasPrefix(NSHomeDirectory() + "/Applications/")
    }

    static func set(_ on: Bool) throws {
        if on {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
        Diag.log("로그인 시 자동 실행 → \(on ? "켜기" : "끄기"), 상태=\(describe(status))")
    }

    static func openSettings() { SMAppService.openSystemSettingsLoginItems() }

    static func describe(_ s: SMAppService.Status) -> String {
        switch s {
        case .enabled: return "켜짐"
        case .notRegistered: return "꺼짐"
        case .requiresApproval: return "승인 필요"
        case .notFound: return "찾을 수 없음"
        @unknown default: return "알 수 없음"
        }
    }
}
