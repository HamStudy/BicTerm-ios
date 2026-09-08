// swift-tools-version:6.1
import PackageDescription

let package = Package(
    name: "BicTermCore",
    platforms: [
        .iOS(.v18),
    ],
    products: [
        .library(name: "BicTermCore", targets: ["BicTermCore"]),
    ],
    dependencies: [
        .package(path: "../Vendor/swift-nio-ssh"),
        .package(url: "https://github.com/apple/swift-nio", exact: "2.102.0"),
    ],
    targets: [
        .target(
            name: "CBcryptPBKDF",
            exclude: ["LICENSES"],
            publicHeadersPath: "include"
        ),
        // The Go tailnet core. Test-target-only: production code reaches it
        // through the CoderTunneling protocol (dependency inversion), and the
        // sole production linkage stays the CoderTunnel framework target's
        // (xcodegen-controlled, excluded from AppStore flavors). The path is
        // produced by scripts/build-coder-net.sh; test-core.sh preflights it.
        .binaryTarget(
            name: "CoderNet",
            path: "../.build-artifacts/coder-net/CoderNet.xcframework"
        ),
        .target(
            name: "BicTermCore",
            dependencies: [
                "CBcryptPBKDF",
                .product(name: "NIOSSH", package: "swift-nio-ssh"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
            ]
        ),
        .testTarget(
            name: "BicTermCoreTests",
            dependencies: [
                "BicTermCore",
                "CoderNet",
                .product(name: "NIOSSH", package: "swift-nio-ssh"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOEmbedded", package: "swift-nio"),
            ],
            linkerSettings: [
                // Go c-archive DNS resolver symbols (_res_9_ninit/_res_9_nclose).
                .linkedLibrary("resolv"),
            ]
        ),
    ]
)
