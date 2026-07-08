// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MediaPlayback",
    platforms: [.iOS("26.0")],
    products: [
        .library(name: "MediaPlayback", targets: ["MediaPlayback"])
    ],
    targets: [
        // Deliberately depends on NO local package: it imports AVFoundation,
        // which transitively needs Apple's system `MediaCore` framework — a
        // dependency on our `MediaCore` module would shadow it and cycle.
        .target(name: "MediaPlayback"),
        .testTarget(name: "MediaPlaybackTests", dependencies: ["MediaPlayback"])
    ]
)
