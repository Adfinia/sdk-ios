// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "AdfiniaSDK",
    platforms: [
        .iOS(.v16),
        .macOS(.v13),
        .tvOS(.v16),
        .watchOS(.v9)
    ],
    products: [
        .library(name: "AdfiniaSDK", targets: ["AdfiniaSDK"])
    ],
    targets: [
        .target(
            name: "AdfiniaSDK",
            path: "Sources/AdfiniaSDK"
        ),
        .testTarget(
            name: "AdfiniaSDKTests",
            dependencies: ["AdfiniaSDK"],
            path: "Tests/AdfiniaSDKTests"
        )
    ]
)
