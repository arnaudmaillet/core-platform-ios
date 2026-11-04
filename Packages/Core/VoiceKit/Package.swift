// swift-tools-version: 6.0
import PackageDescription

// Voice messages' engine (#2101, epic #2105): recording, the waveform, the one
// voice player, the audio session and the microphone permission — no UI but a
// DEBUG lab. AVFoundation lives here, outside the features, as it does in
// MediaPlayback.
//
// ⚠️ IT DEPENDS ON NO LOCAL PACKAGE BUT CACHEKIT, for MediaPlayback's reason:
// AVFoundation needs Apple's system `MediaCore` framework, which a dependency
// on our `MediaCore` module would shadow. CacheKit depends on nothing.
let package = Package(
    name: "VoiceKit",
    platforms: [.iOS("26.0")],
    products: [
        .library(name: "VoiceKit", targets: ["VoiceKit"])
    ],
    dependencies: [
        .package(path: "../CacheKit")
    ],
    targets: [
        .target(name: "VoiceKit", dependencies: ["CacheKit"]),
        .testTarget(name: "VoiceKitTests", dependencies: ["VoiceKit", "CacheKit"])
    ]
)
