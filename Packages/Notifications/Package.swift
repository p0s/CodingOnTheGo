// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Notifications",
    platforms: [
        .iOS(.v18),
        .macOS(.v15)
    ],
    products: [
        .library(
            name: "Notifications",
            targets: ["Notifications"]
        )
    ],
    dependencies: [
        .package(path: "../SharedModels")
    ],
    targets: [
        .target(
            name: "Notifications",
            dependencies: ["SharedModels"]
        ),
        .testTarget(
            name: "NotificationsTests",
            dependencies: ["Notifications"]
        )
    ]
)
