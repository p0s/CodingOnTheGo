// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "FeatureMachines",
    platforms: [
        .iOS(.v18),
        .macOS(.v15)
    ],
    products: [
        .library(
            name: "FeatureMachines",
            targets: ["FeatureMachines"]
        )
    ],
    dependencies: [
        .package(path: "../SharedModels"),
        .package(path: "../Discovery")
    ],
    targets: [
        .target(
            name: "FeatureMachines",
            dependencies: [
                "SharedModels",
                "Discovery"
            ]
        ),
        .testTarget(
            name: "FeatureMachinesTests",
            dependencies: ["FeatureMachines"]
        )
    ]
)
