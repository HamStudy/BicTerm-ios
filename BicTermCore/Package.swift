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
        .package(url: "https://github.com/apple/swift-nio-ssh", exact: "0.15.0"),
    ],
    targets: [
        .target(
            name: "BicTermCore",
            dependencies: [
                .product(name: "NIOSSH", package: "swift-nio-ssh"),
            ]
        ),
        .testTarget(
            name: "BicTermCoreTests",
            dependencies: [
                "BicTermCore",
                .product(name: "NIOSSH", package: "swift-nio-ssh"),
            ]
        ),
    ]
)
