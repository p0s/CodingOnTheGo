// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "FeatureComposer",
    platforms: [
        .iOS(.v18),
        .macOS(.v15)
    ],
    products: [
        .library(
            name: "FeatureComposer",
            targets: ["FeatureComposer"]
        )
    ],
    targets: [
        .target(name: "FeatureComposer"),
        .testTarget(
            name: "FeatureComposerTests",
            dependencies: ["FeatureComposer"]
        )
    ]
)
