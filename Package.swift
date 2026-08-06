// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MenuBarApp",
    platforms: [
        .macOS(.v14)
    ],
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm", from: "1.15.0")
    ],
    targets: [
        .executableTarget(
            name: "MenuBarApp",
            dependencies: [
                .product(name: "SwiftTerm", package: "SwiftTerm")
            ],
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
