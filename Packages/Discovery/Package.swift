// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Discovery",
    platforms: [
        .iOS(.v18),
        .macOS(.v15)
    ],
    products: [
        .library(
            name: "Discovery",
            targets: ["Discovery"]
        )
    ],
    dependencies: [
        .package(path: "../SharedModels"),
        .package(path: "../CompanionHost")
    ],
    targets: [
        .target(
            name: "Discovery",
            dependencies: [
                "SharedModels",
                "CompanionHost"
            ]
        ),
        .testTarget(
            name: "DiscoveryTests",
            dependencies: ["Discovery"]
        )
    ]
)
