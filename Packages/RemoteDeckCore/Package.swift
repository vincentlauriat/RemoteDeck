// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "RemoteDeckCore",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "RemoteDeckCore", targets: ["RemoteDeckCore"]),
    ],
    targets: [
        .target(name: "RemoteDeckCore"),
        .testTarget(name: "RemoteDeckCoreTests", dependencies: ["RemoteDeckCore"]),
    ]
)
