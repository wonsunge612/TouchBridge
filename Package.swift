// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "TouchBridge",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "TouchBridge",
            path: "Sources/TouchBridge",
            linkerSettings: [
                .linkedFramework("IOKit"),
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI"),
                .linkedFramework("ApplicationServices"),
            ]
        )
    ]
)
