// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "FeatureReview",
    platforms: [
        .iOS(.v18),
        .macOS(.v15)
    ],
    products: [
        .library(
            name: "FeatureReview",
            targets: ["FeatureReview"]
        )
    ],
    dependencies: [
        .package(path: "../GitWorkspace")
    ],
    targets: [
        .target(
            name: "FeatureReview",
            dependencies: ["GitWorkspace"]
        ),
        .testTarget(
            name: "FeatureReviewTests",
            dependencies: ["FeatureReview"]
        )
    ]
)
