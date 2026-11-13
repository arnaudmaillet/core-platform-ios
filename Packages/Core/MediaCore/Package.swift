// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MediaCore",
    platforms: [.iOS("26.0")],
    products: [
        .library(name: "MediaCore", targets: ["MediaCore"])
    ],
    dependencies: [
        .package(path: "../../Kit/LaunchArguments"),
        // `MotionPreference`: the app-level Reduce Motion the animated icons
        // honour alongside the iOS setting (#468).
        .package(path: "../DesignSystem"),
        // The device cache (#891): resident animated icons live in its UI
        // assets class (#971); the image pipeline's memory and disk caches,
        // fills and budgets (#894).
        .package(path: "../CacheKit"),
        // `HostRewrite` (#2373): the dev host mapping the image fetcher and
        // CoreNetworking's upload transport share.
        .package(path: "../../Kit/CoreModels")
    ],
    targets: [
        .target(name: "MediaCore", dependencies: ["LaunchArguments", "DesignSystem", "CacheKit", "CoreModels"]),
        .testTarget(name: "MediaCoreTests", dependencies: ["MediaCore", "CacheKit"])
    ]
)
