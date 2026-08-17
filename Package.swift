// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "panewatch",
    // .v14 rather than the host's macOS 15: nothing in SPEC.md needs a macOS 15 API,
    // and the lower floor costs nothing. Raise it only when one turns up.
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "TmuxCore", targets: ["TmuxCore"]),
        .executable(name: "PaneWatchApp", targets: ["PaneWatchApp"])
    ],
    dependencies: [
        // TASK-015: embeds the Hover Preview Popup's live terminal. PaneWatchApp only, never
        // TmuxCore — see CLAUDE.md ("TmuxCore must stay free of AppKit").
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", from: "1.18.0")
    ],
    targets: [
        // Pure logic — no AppKit, so it tests headlessly.
        .target(name: "TmuxCore"),
        .testTarget(name: "TmuxCoreTests", dependencies: ["TmuxCore"]),
        // AppKit/SwiftUI shell. Depends on TmuxCore, never the reverse — see CLAUDE.md.
        .executableTarget(name: "PaneWatchApp", dependencies: [
            "TmuxCore",
            .product(name: "SwiftTerm", package: "SwiftTerm")
        ]),
        .testTarget(name: "PaneWatchAppTests", dependencies: ["PaneWatchApp"])
    ]
)
