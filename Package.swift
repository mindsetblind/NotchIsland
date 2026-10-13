// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "NotchIsland",
    platforms: [.macOS(.v14)],
    dependencies: [
        // Automatic updates from GitHub Releases (EdDSA-signed).
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.9.6"),
    ],
    targets: [
        // UI-free logic (activity coordination, clipboard history, developer events…), unit-tested.
        .target(name: "NotchIslandCore", path: "Sources/NotchIslandCore"),
        .executableTarget(
            name: "NotchIsland",
            dependencies: ["NotchIslandCore", .product(name: "Sparkle", package: "Sparkle")],
            path: "Sources/NotchIsland",
            // Sparkle.framework is embedded in NotchIsland.app/Contents/Frameworks by the build scripts.
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]
        ),
        // Tiny helper that Claude Code runs on hook events; bundled inside NotchIsland.app.
        .executableTarget(name: "notchisland-hook", path: "Sources/notchisland-hook"),
        // Command-line companion for Developer Mode (reports builds/tests/scripts); also bundled.
        .executableTarget(name: "notchisland-cli", path: "Sources/notchisland-cli"),
        .testTarget(name: "NotchIslandCoreTests", dependencies: ["NotchIslandCore"], path: "Tests/NotchIslandCoreTests"),
    ]
)
