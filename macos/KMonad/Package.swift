// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "KMonad",
    platforms: [.macOS(.v13)],
    targets: [
        // Pure logic: supervisor state machine, config parsing, status model.
        .target(name: "KMonadCore"),
        // The app: menu bar UI, root daemon (--daemon) and CLI.
        .executableTarget(name: "KMonad", dependencies: ["KMonadCore"]),
        .testTarget(name: "KMonadCoreTests", dependencies: ["KMonadCore"]),
    ]
)
