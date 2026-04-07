// swift-tools-version: 6.0
import Foundation
import PackageDescription

let packageDirectory = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
let repoRoot = packageDirectory
    .deletingLastPathComponent()
    .deletingLastPathComponent()

func firstExistingDirectory(_ candidates: [String]) -> String? {
    let fileManager = FileManager.default
    return candidates.first { candidate in
        var isDirectory: ObjCBool = false
        return fileManager.fileExists(atPath: candidate, isDirectory: &isDirectory) && isDirectory.boolValue
    }
}

let configuredTailscaleKitPath = ProcessInfo.processInfo.environment["COTG_TAILSCALEKIT_PACKAGE_PATH"]?
    .trimmingCharacters(in: .whitespacesAndNewlines)
let tailscaleKitPackagePath = firstExistingDirectory(
    [
        configuredTailscaleKitPath,
        repoRoot.appending(path: "Vendor").appending(path: "TailscaleKit").path,
        repoRoot.appending(path: "Vendor").appending(path: "tailscale").appending(path: "TailscaleKit").path
    ].compactMap { candidate in
        guard let candidate, !candidate.isEmpty else {
            return nil
        }
        return candidate
    }
)

var dependencies: [Package.Dependency] = [
    .package(path: "../SharedModels")
]
var targetDependencies: [Target.Dependency] = [
    "SharedModels"
]

if let tailscaleKitPackagePath {
    dependencies.append(.package(path: tailscaleKitPackagePath))
    targetDependencies.append(.product(name: "TailscaleKit", package: "TailscaleKit"))
}

let package = Package(
    name: "TailnetEmbedded",
    platforms: [
        .iOS(.v18),
        .macOS(.v15)
    ],
    products: [
        .library(
            name: "TailnetEmbedded",
            targets: ["TailnetEmbedded"]
        )
    ],
    dependencies: dependencies,
    targets: [
        .target(
            name: "TailnetEmbedded",
            dependencies: targetDependencies
        ),
        .testTarget(
            name: "TailnetEmbeddedTests",
            dependencies: ["TailnetEmbedded"]
        )
    ]
)
