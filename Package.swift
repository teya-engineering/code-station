// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MenuBarApp",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        // The terminal front end, started as `code-station tui` (ADR-0002).
        .executable(name: "code-station", targets: ["CodeStationTUI"]),
        .executable(name: "MenuBarApp", targets: ["MenuBarApp"])
    ],
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm", from: "1.15.0")
    ],
    targets: [
        .target(
            name: "CodeStationCore",
            path: "Sources/CodeStationCore"
        ),
        // The terminal layer: raw mode, the alternate screen, key decoding and a screen
        // that repaints only the lines that changed. Darwin and Dispatch only.
        .target(
            name: "TerminalKit",
            path: "Sources/TerminalKit"
        ),
        // The transcript renderer: a session's messages, a width and a theme in, styled
        // terminal lines out. Pure, so it is tested line by line without a terminal.
        .target(
            name: "TerminalTranscript",
            dependencies: ["CodeStationCore"],
            path: "Sources/TerminalTranscript"
        ),
        // The core's host services answered by a terminal: a bell and OSC 9, OSC 52 for
        // the clipboard, `open` for paths and a typed path for a folder. Every byte goes
        // through a sink the caller hands in, so tests read exactly what was written.
        .target(
            name: "TerminalServices",
            dependencies: ["CodeStationCore", "TerminalKit"],
            path: "Sources/TerminalServices"
        ),
        // Never links AppKit or SwiftUI: it depends only on the core and the terminal
        // targets.
        .executableTarget(
            name: "CodeStationTUI",
            dependencies: ["CodeStationCore", "TerminalKit", "TerminalTranscript", "TerminalServices"],
            path: "Sources/CodeStationTUI"
        ),
        .executableTarget(
            name: "MenuBarApp",
            dependencies: [
                "CodeStationCore",
                .product(name: "SwiftTerm", package: "SwiftTerm")
            ],
            path: "Sources/MenuBarApp",
            resources: [.process("Resources")]
        ),
        .testTarget(
            name: "MenuBarAppTests",
            dependencies: ["MenuBarApp", "CodeStationCore"],
            path: "Tests/MenuBarAppTests"
        ),
        .testTarget(
            name: "TerminalKitTests",
            dependencies: ["TerminalKit"],
            path: "Tests/TerminalKitTests"
        ),
        .testTarget(
            name: "TerminalTranscriptTests",
            dependencies: ["TerminalTranscript", "CodeStationCore"],
            path: "Tests/TerminalTranscriptTests"
        ),
        .testTarget(
            name: "TerminalServicesTests",
            dependencies: ["TerminalServices", "CodeStationCore"],
            path: "Tests/TerminalServicesTests"
        ),
        // The TUI run headless: keys, sizes and station events in, the frame it draws out
        // as lines of styled text, over an in-process station on a scratch store.
        .testTarget(
            name: "CodeStationTUITests",
            dependencies: ["CodeStationTUI", "CodeStationCore", "TerminalKit", "TerminalTranscript"],
            path: "Tests/CodeStationTUITests"
        )
    ]
)
