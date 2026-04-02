// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SyncEngine",
    platforms: [
        .iOS(.v18),
        .macOS(.v15)
    ],
    products: [
        .library(
            name: "SyncEngine",
            targets: ["SyncEngine"]
        )
    ],
    dependencies: [
        .package(path: "../SharedModels"),
        .package(path: "../Persistence")
    ],
    targets: [
        .target(
            name: "SyncEngine",
            dependencies: [
                "SharedModels",
                "Persistence"
            ]
        ),
        .testTarget(
            name: "SyncEngineTests",
            dependencies: ["SyncEngine"]
        )
    ]
)
