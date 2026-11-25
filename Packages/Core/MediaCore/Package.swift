// swift-tools-version: 6.0
import PackageDescription

// Two targets (#2384):
// - MediaCore, the media pipeline: image fetching, decoding and caching, the
//   lookahead, the animated icon and avatar sheets, the launch curtain. It
//   draws nothing of the app's design and does not depend on DesignSystem.
// - MediaUI, the views drawn over it: avatars and group avatars, person pills
//   and relation marks, the loading slots and ladder, the animated icon and
//   avatar players. They wear the design system's tokens, so DesignSystem
//   comes in here and only here.
// And MediaCoreFixtures (#2516), mock media: the placeholder fetcher that
// draws a colour for a `mock://` URL and the scheme router that sends
// `mock://` to it. The mock app target and the tests link it; the
// production target never does, so the production app carries none of it.
let package = Package(
    name: "MediaCore",
    platforms: [.iOS("26.0")],
    products: [
        .library(name: "MediaCore", targets: ["MediaCore"]),
        .library(name: "MediaUI", targets: ["MediaUI"]),
        .library(name: "MediaCoreFixtures", targets: ["MediaCoreFixtures"])
    ],
    dependencies: [
        .package(path: "../../Kit/LaunchArguments"),
        // MediaUI only: the tokens its views wear, and `MotionPreference`, the
        // app-level Reduce Motion the animated icons honour alongside the iOS
        // setting (#468).
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
        .target(name: "MediaCore", dependencies: ["LaunchArguments", "CacheKit", "CoreModels"]),
        .target(name: "MediaUI", dependencies: ["MediaCore", "CoreModels", "DesignSystem", "LaunchArguments", "CacheKit"]),
        .target(name: "MediaCoreFixtures", dependencies: ["MediaCore", "LaunchArguments", "CacheKit"]),
        .testTarget(name: "MediaCoreTests", dependencies: ["MediaCore", "MediaCoreFixtures", "CacheKit"]),
        .testTarget(
            name: "MediaUITests",
            dependencies: ["MediaUI", "MediaCore", "MediaCoreFixtures", "DesignSystem", "CacheKit"]
        )
    ]
)
