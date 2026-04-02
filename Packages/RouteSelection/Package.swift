// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "RouteSelection",
    platforms: [
        .iOS(.v18),
        .macOS(.v15)
    ],
    products: [
        .library(
            name: "RouteSelection",
            targets: ["RouteSelection"]
        )
    ],
    dependencies: [
        .package(path: "../SharedModels"),
        .package(path: "../TailnetEmbedded"),
        .package(path: "../SSHTransport"),
        .package(path: "../HostBootstrap"),
        .package(path: "../CodexRPC"),
        .package(path: "../CompanionHost"),
        .package(path: "../Discovery")
    ],
    targets: [
        .target(
            name: "RouteSelection",
            dependencies: [
                "SharedModels",
                "TailnetEmbedded",
                "SSHTransport",
                "HostBootstrap",
                "CodexRPC",
                "CompanionHost",
                "Discovery"
            ]
        ),
        .testTarget(
            name: "RouteSelectionTests",
            dependencies: ["RouteSelection"]
        )
    ]
)
