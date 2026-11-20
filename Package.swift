// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "MenuBarApp",
    platforms: [
        .macOS(.v15)
    ],
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm", from: "1.99.1"),
        .package(url: "https://github.com/apple/swift-nio", from: "2.105.0"),
        .package(url: "https://github.com/jpsim/Yams", from: "6.2.2"),
        .package(url: "https://github.com/swiftlang/swift-markdown", from: "0.9.0")
    ],
    targets: [
        .executableTarget(
            name: "MenuBarApp",
            dependencies: [
                .product(name: "SwiftTerm", package: "SwiftTerm"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
                .product(name: "NIOWebSocket", package: "swift-nio"),
                .product(name: "Yams", package: "Yams"),
                .product(name: "Markdown", package: "swift-markdown")
            ],
            path: "Sources/MenuBarApp",
            resources: [.process("Resources")]
        ),
        .testTarget(
            name: "MenuBarAppTests",
            dependencies: [
                "MenuBarApp",
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio")
            ],
            path: "Tests/MenuBarAppTests"
        )
    ]
)
