// swift-tools-version: 6.0
import PackageDescription

// The Claude Assistant's protocol side (TRD › Claude Assistant): Messages API request and response,
// the computer use toolset, screenshot sizing and encoding, and the mapping of Claude's actions to
// RFB input. No UI and no app state, so `swift test` covers it without the hosted app.
let package = Package(
    name: "ClaudeKit",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "ClaudeKit", targets: ["ClaudeKit"]),
    ],
    dependencies: [
        .package(path: "../RFBKit"),
    ],
    targets: [
        .target(name: "ClaudeKit", dependencies: ["RFBKit"]),
        .testTarget(name: "ClaudeKitTests", dependencies: ["ClaudeKit", "RFBKit"]),
    ]
)
