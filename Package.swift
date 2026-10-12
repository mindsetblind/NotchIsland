// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "NotchIsland",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "NotchIsland", path: "Sources"),
        // Tiny helper that Claude Code runs on hook events; bundled inside NotchIsland.app.
        .executableTarget(name: "notchisland-hook", path: "Hook")
    ]
)
