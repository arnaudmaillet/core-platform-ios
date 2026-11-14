// swift-tools-version: 6.0
import PackageDescription

/// The launch arguments (#2374): a leaf, so declaring a flag rebuilds only
/// what reads it, not the 18 packages under DesignSystem.
let package = Package(
    name: "LaunchArguments",
    platforms: [.iOS("26.0")],
    products: [
        .library(name: "LaunchArguments", targets: ["LaunchArguments"])
    ],
    targets: [
        .target(name: "LaunchArguments"),
        .testTarget(name: "LaunchArgumentsTests", dependencies: ["LaunchArguments"])
    ]
)
