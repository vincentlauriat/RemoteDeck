// swift-tools-version: 6.0
import PackageDescription

// SSH machines (Step 7): host keys, ssh_config, private keys, and later the connection, port
// forwards and SFTP. No UI and no app state; the SSH library's types never leave this package.
//
// The library is Citadel 0.12.0 on swift-nio-ssh 0.3.5, both vendored and patched under
// Packages/Vendor (see Packages/Vendor/PATCHES.md). Every remote package they bring in is pinned
// here with `exact:`, at the versions the SSH spike resolved, and listed as a dependency of the
// SSHKit target so the pin also holds when SSHKit is not the root package (the app's Xcode build):
// a declared but unused dependency may be pruned from resolution, and its pin with it.
let package = Package(
    name: "SSHKit",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "SSHKit", targets: ["SSHKit"]),
    ],
    dependencies: [
        .package(path: "../Vendor/Citadel"),
        .package(path: "../Vendor/swift-nio-ssh"),
        .package(url: "https://github.com/apple/swift-nio.git", exact: "2.105.0"),
        .package(url: "https://github.com/apple/swift-crypto.git", exact: "3.15.1"),
        .package(url: "https://github.com/apple/swift-asn1.git", exact: "1.7.4"),
        .package(url: "https://github.com/apple/swift-atomics.git", exact: "1.3.1"),
        .package(url: "https://github.com/apple/swift-collections.git", exact: "1.7.5"),
        .package(url: "https://github.com/apple/swift-log.git", exact: "1.17.0"),
        .package(url: "https://github.com/apple/swift-system.git", exact: "1.8.1"),
        .package(url: "https://github.com/attaswift/BigInt.git", exact: "5.7.0"),
    ],
    targets: [
        .target(
            name: "SSHKit",
            dependencies: [
                .product(name: "Citadel", package: "Citadel"),
                .product(name: "NIOSSH", package: "swift-nio-ssh"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "_CryptoExtras", package: "swift-crypto"),
                // Not imported by SSHKit: listed only so their `exact:` pins above stay in the
                // graph (they are linked anyway, through NIO, swift-crypto and Citadel).
                .product(name: "SwiftASN1", package: "swift-asn1"),
                .product(name: "Atomics", package: "swift-atomics"),
                .product(name: "DequeModule", package: "swift-collections"),
                .product(name: "Logging", package: "swift-log"),
                .product(name: "SystemPackage", package: "swift-system"),
                .product(name: "BigInt", package: "BigInt"),
            ]
        ),
        .testTarget(
            name: "SSHKitTests",
            dependencies: [
                "SSHKit",
                .product(name: "NIOSSH", package: "swift-nio-ssh"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOEmbedded", package: "swift-nio"),
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "_CryptoExtras", package: "swift-crypto"),
            ],
            // Keys generated with ssh-keygen for these tests only (never used anywhere else).
            resources: [.copy("Fixtures")]
        ),
    ]
)
