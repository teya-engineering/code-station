// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MenuBarApp",
    platforms: [
        .macOS(.v14)
    ],
    targets: [
        .executableTarget(
            name: "MenuBarApp",
            path: "Sources/MenuBarApp",
            resources: [.process("Resources")]
        ),
        .testTarget(
            name: "MenuBarAppTests",
            dependencies: ["MenuBarApp"],
            path: "Tests/MenuBarAppTests"
        )
    ]
)
