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
        // Live probe against a real server (`swift run rfb-probe <host>`); not a product, and the
        // library does not depend on it.
        .executableTarget(name: "rfb-probe", dependencies: ["RFBKit"]),
        .testTarget(
            name: "RFBKitTests",
            dependencies: ["RFBKit"],
            // Generator script for the test vectors and the placeholder for real captures.
            exclude: ["Vectors", "Captures"]
        ),
    ]
)
