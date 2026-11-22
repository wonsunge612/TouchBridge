import Foundation

/// ~/Library/Logs/TouchBridge.log 에 동작 상태를 남긴다 (실행할 때마다 새로 시작).
/// 권한, 장치 독점 여부, 매핑 결과, 제스처 판정을 사람이 읽을 수 있게 기록한다.
enum Diag {
    static let url: URL = {
        if let p = ProcessInfo.processInfo.environment["TOUCHBRIDGE_LOG"] { return URL(fileURLWithPath: p) }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/TouchBridge.log")
    }()

    private static let handle: FileHandle? = {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        return try? FileHandle(forWritingTo: url)
    }()

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    static func log(_ msg: @autoclosure () -> String) {
        let line = "\(formatter.string(from: Date())) \(msg())\n"
        handle?.write(Data(line.utf8))
        NSLog("TouchBridge: %@", msg())
    }

    static func fmt(_ p: CGPoint) -> String { String(format: "(%.0f,%.0f)", p.x, p.y) }
    static func fmtN(_ p: CGPoint) -> String { String(format: "(%.3f,%.3f)", p.x, p.y) }
}
