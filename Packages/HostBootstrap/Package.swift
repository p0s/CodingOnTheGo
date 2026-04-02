// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "HostBootstrap",
    platforms: [
        .iOS(.v18),
        .macOS(.v15)
    ],
    products: [
        .library(
            name: "HostBootstrap",
            targets: ["HostBootstrap"]
        )
    ],
    dependencies: [
        .package(path: "../SharedModels")
    ],
    targets: [
        .target(
            name: "HostBootstrap",
            dependencies: ["SharedModels"]
        ),
        .testTarget(
            name: "HostBootstrapTests",
            dependencies: ["HostBootstrap"]
        )
    ]
)
