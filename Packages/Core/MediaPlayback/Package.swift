// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MediaPlayback",
    platforms: [.iOS("26.0")],
    products: [
        .library(name: "MediaPlayback", targets: ["MediaPlayback"])
    ],
    dependencies: [
        // The device cache (#891): video bytes live in its `.video` disk pool
        // (#895). CacheKit depends on nothing, so it cannot cycle.
        .package(path: "../CacheKit")
    ],
    targets: [
        // Deliberately depends on no OTHER local package: it imports
        // AVFoundation, which transitively needs Apple's system `MediaCore`
        // framework — a dependency on our `MediaCore` module would shadow it
        // and cycle.
        .target(name: "MediaPlayback", dependencies: ["CacheKit"]),
        .testTarget(name: "MediaPlaybackTests", dependencies: ["MediaPlayback", "CacheKit"])
    ]
)
