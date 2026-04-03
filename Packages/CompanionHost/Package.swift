// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CompanionHost",
    platforms: [
        .iOS(.v18),
        .macOS(.v15)
    ],
    products: [
        .library(
            name: "CompanionHost",
            targets: ["CompanionHost"]
        )
    ],
    dependencies: [
        .package(path: "../SharedModels"),
        .package(path: "../Persistence"),
        .package(path: "../SyncEngine"),
        .package(path: "../Notifications")
    ],
    targets: [
        .target(
            name: "CompanionHost",
            dependencies: ["SharedModels", "Persistence", "SyncEngine", "Notifications"]
        ),
        .testTarget(
            name: "CompanionHostTests",
            dependencies: ["CompanionHost"]
        )
    ]
)
