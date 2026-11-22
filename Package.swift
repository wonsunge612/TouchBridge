// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "TouchBridge",
    platforms: [.macOS(.v13)],
    dependencies: [
        // 자동 업데이트 (appcast + EdDSA 서명)
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.10.0"),
    ],
    targets: [
        .executableTarget(
            name: "TouchBridge",
            dependencies: [.product(name: "Sparkle", package: "Sparkle")],
            path: "Sources/TouchBridge",
            linkerSettings: [
                .linkedFramework("IOKit"),
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI"),
                .linkedFramework("ApplicationServices"),
                // 앱 번들의 Contents/Frameworks/Sparkle.framework 를 찾도록
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"]),
            ]
        )
    ]
)
