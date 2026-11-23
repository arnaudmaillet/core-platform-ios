// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MediaPlayback",
    platforms: [.iOS("26.0")],
    products: [
        .library(name: "MediaPlayback", targets: ["MediaPlayback"]),
        // Mock media (#2516): `PlaceholderVideoFetcher`, which synthesises a
        // clip for a `mock://` URL. The mock app target and the tests link
        // it; the production target never does.
        .library(name: "MediaPlaybackFixtures", targets: ["MediaPlaybackFixtures"])
    ],
    dependencies: [
        // The device cache (#891): video bytes live in its `.video` disk pool
        // (#895). CacheKit depends on nothing, so it cannot cycle.
        .package(path: "../CacheKit"),
        // `AudioFocus` (#2373): the voice engine's floor, read by name.
        // CoreModels depends on nothing, so it neither shadows nor cycles.
        .package(path: "../../Kit/CoreModels"),
        // Its launch arguments, declared (#2374). LaunchArguments depends on
        // nothing, so it neither shadows nor cycles.
        .package(path: "../../Kit/LaunchArguments")
    ],
    targets: [
        // Deliberately depends on no OTHER local package but CoreModels and
        // LaunchArguments (which depend on nothing): it imports
        // AVFoundation, which transitively needs Apple's system `MediaCore`
        // framework — a dependency on our `MediaCore` module would shadow it
        // and cycle.
        .target(name: "MediaPlayback", dependencies: ["CacheKit", "CoreModels", "LaunchArguments"]),
        .target(name: "MediaPlaybackFixtures", dependencies: ["MediaPlayback", "LaunchArguments"]),
        .testTarget(name: "MediaPlaybackTests", dependencies: ["MediaPlayback", "MediaPlaybackFixtures", "CacheKit"])
    ]
)
