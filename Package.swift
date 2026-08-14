// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "tmuxer",
    // .v14 rather than the host's macOS 15: nothing in SPEC.md needs a macOS 15 API,
    // and the lower floor costs nothing. Raise it only when one turns up.
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "TmuxCore", targets: ["TmuxCore"]),
        .executable(name: "TmuxerApp", targets: ["TmuxerApp"])
    ],
    targets: [
        // Pure logic — no AppKit, so it tests headlessly.
        .target(name: "TmuxCore"),
        .testTarget(name: "TmuxCoreTests", dependencies: ["TmuxCore"]),
        // AppKit/SwiftUI shell. Depends on TmuxCore, never the reverse — see CLAUDE.md.
        .executableTarget(name: "TmuxerApp", dependencies: ["TmuxCore"])
    ]
)
