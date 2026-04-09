// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AppState",
    platforms: [
        .iOS(.v18),
        .macOS(.v15)
    ],
    products: [
        .library(
            name: "AppState",
            targets: ["AppState"]
        )
    ],
    dependencies: [
        .package(path: "../SharedModels"),
        .package(path: "../RouteSelection"),
        .package(path: "../CodexRPC"),
        .package(path: "../HostBootstrap"),
        .package(path: "../SSHTransport"),
        .package(path: "../Persistence"),
        .package(path: "../SyncEngine"),
        .package(path: "../Secrets"),
        .package(path: "../Discovery"),
        .package(path: "../GitWorkspace"),
        .package(path: "../Notifications"),
        .package(path: "../FeatureMachines"),
        .package(path: "../FeatureThreads"),
        .package(path: "../FeatureComposer"),
        .package(path: "../TailnetEmbedded"),
        .package(path: "../CompanionHost")
    ],
    targets: [
        .target(
            name: "AppState",
            dependencies: [
                "SharedModels",
                "RouteSelection",
                "CodexRPC",
                "HostBootstrap",
                "SSHTransport",
                "Persistence",
                "SyncEngine",
                "Secrets",
                "Discovery",
                "GitWorkspace",
                "Notifications",
                "FeatureMachines",
                "FeatureThreads",
                "FeatureComposer",
                "TailnetEmbedded",
                "CompanionHost"
            ]
        ),
        .testTarget(
            name: "AppStateTests",
            dependencies: ["AppState"]
        )
    ]
)
