// swift-tools-version: 6.0
import PackageDescription

// The SSH terminal's engine (TRD › Architecture › SSH › Terminal engine): libghostty-vt 1.0.0, the
// official prebuilt XCFramework (static library, C module `GhosttyVt`), pinned by URL and SHA-256 (the
// spike report: the minisign signature was checked with Ghostty's release key, and this checksum is
// `swift package compute-checksum` of that zip). No Zig in the build. `GhosttyEngine` is a thin Swift
// layer over the C API with no UI: the app draws the cells (`RemoteDeck/SSH/TerminalSurface.swift`).
//
// The Swift module is not named after the C module on purpose: `GhosttyVT` and `GhosttyVt` would
// collide on a case-insensitive volume.
let package = Package(
    name: "GhosttyVT",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "GhosttyEngine", targets: ["GhosttyEngine"]),
    ],
    targets: [
        .binaryTarget(
            name: "GhosttyVt",
            url: "https://release.files.ghostty.org/libghostty-vt/1.0.0/ghostty-vt-1.0.0.xcframework.zip",
            checksum: "2c32b7409b2b6c2ef6cfd606526de357762ad458bdc27134ad074e86506a8bc2"
        ),
        .target(
            name: "GhosttyEngine",
            dependencies: ["GhosttyVt"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "GhosttyEngineTests",
            dependencies: ["GhosttyEngine"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
