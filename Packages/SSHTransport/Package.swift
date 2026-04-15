// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SSHTransport",
    platforms: [
        .iOS(.v18),
        .macOS(.v15)
    ],
    products: [
        .library(
            name: "SSHTransport",
            targets: ["SSHTransport"]
        )
    ],
    dependencies: [
        .package(path: "../SharedModels"),
        .package(path: "../CodexRPC"),
        .package(path: "../HostBootstrap"),
        .package(url: "https://github.com/gaetanzanella/swift-ssh-client", exact: "0.1.4"),
        .package(url: "https://github.com/apple/swift-nio-ssh", exact: "0.6.0")
    ],
    targets: [
        .target(
            name: "SSHTransport",
            dependencies: [
                "SharedModels",
                "CodexRPC",
                "HostBootstrap",
                .product(name: "SSHClient", package: "swift-ssh-client"),
                .product(name: "NIOSSH", package: "swift-nio-ssh")
            ]
        ),
        .testTarget(
            name: "SSHTransportTests",
            dependencies: ["SSHTransport"]
        )
    ]
)
