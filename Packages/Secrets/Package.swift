// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Secrets",
    platforms: [
        .iOS(.v18),
        .macOS(.v15)
    ],
    products: [
        .library(
            name: "Secrets",
            targets: ["Secrets"]
        )
    ],
    dependencies: [
        .package(path: "../SharedModels")
    ],
    targets: [
        .target(
            name: "Secrets",
            dependencies: ["SharedModels"]
        ),
        .testTarget(
            name: "SecretsTests",
            dependencies: ["Secrets"]
        )
    ]
)
