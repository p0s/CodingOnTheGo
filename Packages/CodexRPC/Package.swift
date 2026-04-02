// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CodexRPC",
    platforms: [
        .iOS(.v18),
        .macOS(.v15)
    ],
    products: [
        .library(
            name: "CodexRPC",
            targets: ["CodexRPC"]
        )
    ],
    dependencies: [
        .package(path: "../SharedModels")
    ],
    targets: [
        .target(
            name: "CodexRPC",
            dependencies: ["SharedModels"]
        ),
        .testTarget(
            name: "CodexRPCTests",
            dependencies: ["CodexRPC"]
        )
    ]
)
