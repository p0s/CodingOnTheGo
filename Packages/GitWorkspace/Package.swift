// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "GitWorkspace",
    platforms: [
        .iOS(.v18),
        .macOS(.v15)
    ],
    products: [
        .library(
            name: "GitWorkspace",
            targets: ["GitWorkspace"]
        )
    ],
    dependencies: [
        .package(path: "../SharedModels")
    ],
    targets: [
        .target(
            name: "GitWorkspace",
            dependencies: ["SharedModels"]
        ),
        .testTarget(
            name: "GitWorkspaceTests",
            dependencies: ["GitWorkspace"]
        )
    ]
)
