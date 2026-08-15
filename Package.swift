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
    dependencies: [
        // TASK-015: embeds the Hover Preview Popup's live terminal. TmuxerApp only, never
        // TmuxCore — see CLAUDE.md ("TmuxCore must stay free of AppKit").
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", from: "1.18.0")
    ],
    targets: [
        // Pure logic — no AppKit, so it tests headlessly.
        .target(name: "TmuxCore"),
        .testTarget(name: "TmuxCoreTests", dependencies: ["TmuxCore"]),
        // AppKit/SwiftUI shell. Depends on TmuxCore, never the reverse — see CLAUDE.md.
        .executableTarget(name: "TmuxerApp", dependencies: [
            "TmuxCore",
            .product(name: "SwiftTerm", package: "SwiftTerm")
        ]),
        .testTarget(name: "TmuxerAppTests", dependencies: ["TmuxerApp"])
    ]
)
