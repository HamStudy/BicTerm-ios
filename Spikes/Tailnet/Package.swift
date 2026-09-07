// swift-tools-version:6.1
import PackageDescription

let package = Package(
    name: "TailnetSpike",
    platforms: [
        .macOS(.v13),
    ],
    products: [
        .library(name: "TailnetSpike", targets: ["TailnetSpike"]),
        .executable(name: "tailnet-spike", targets: ["TailnetSpikeCLI"]),
        .executable(name: "tailnet-fixture", targets: ["TailnetFixture"]),
    ],
    targets: [
        .target(name: "TailnetSpike"),
        .executableTarget(
            name: "TailnetSpikeCLI",
            dependencies: ["TailnetSpike"]
        ),
        .executableTarget(
            name: "TailnetFixture",
            dependencies: ["TailnetSpike"]
        ),
        .testTarget(
            name: "TailnetSpikeTests",
            dependencies: ["TailnetSpike"]
        ),
    ]
)
