// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "RFBKit",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "RFBKit", targets: ["RFBKit"]),
    ],
    targets: [
        .target(name: "RFBKit"),
        .testTarget(name: "RFBKitTests", dependencies: ["RFBKit"]),
    ]
)
