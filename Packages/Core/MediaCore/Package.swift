// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MediaCore",
    platforms: [.iOS("26.0")],
    products: [
        .library(name: "MediaCore", targets: ["MediaCore"])
    ],
    dependencies: [
        // `MotionPreference`: the app-level Reduce Motion the animated icons
        // honour alongside the iOS setting (#468).
        .package(path: "../DesignSystem")
    ],
    targets: [
        .target(name: "MediaCore", dependencies: ["DesignSystem"]),
        .testTarget(name: "MediaCoreTests", dependencies: ["MediaCore"])
    ]
)
