// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DesignSystem",
    platforms: [.iOS("26.0")],
    products: [
        .library(name: "DesignSystem", targets: ["DesignSystem"])
    ],
    dependencies: [
        // The DEBUG switches (`DebugFlags`, #2374): a leaf, so a new flag
        // no longer rebuilds DesignSystem and everything above it.
        .package(path: "../../Kit/LaunchArguments")
    ],
    targets: [
        .target(
            name: "DesignSystem",
            dependencies: ["LaunchArguments"],
            resources: [.copy("Resources/Sounds"), .process("Resources/Symbols.xcassets")]
        ),
        .testTarget(name: "DesignSystemTests", dependencies: ["DesignSystem"])
    ]
)
