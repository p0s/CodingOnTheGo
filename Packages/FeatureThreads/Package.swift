// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "FeatureThreads",
    platforms: [
        .iOS(.v18),
        .macOS(.v15)
    ],
    products: [
        .library(
            name: "FeatureThreads",
            targets: ["FeatureThreads"]
        )
    ],
    dependencies: [
        .package(path: "../SharedModels")
    ],
    targets: [
        .target(
            name: "FeatureThreads",
            dependencies: ["SharedModels"]
        ),
        .testTarget(
            name: "FeatureThreadsTests",
            dependencies: ["FeatureThreads"]
        )
    ]
)
