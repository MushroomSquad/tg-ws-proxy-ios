// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "TgWsProxyCore",
    platforms: [
        .iOS(.v16),
        .macOS(.v13),
    ],
    products: [
        .library(name: "TgWsProxyCore", targets: ["TgWsProxyCore"]),
    ],
    targets: [
        .target(
            name: "TgWsProxyCore",
            path: "Sources/TgWsProxyCore"
        ),
        .testTarget(
            name: "TgWsProxyCoreTests",
            dependencies: ["TgWsProxyCore"],
            path: "Tests/TgWsProxyCoreTests"
        ),
    ]
)
