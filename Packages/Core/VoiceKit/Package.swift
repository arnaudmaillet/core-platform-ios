// swift-tools-version: 6.0
import PackageDescription

// Voice messages' engine (#2101, epic #2105): recording, the waveform, the one
// voice player, the audio session and the microphone permission — no UI but a
// DEBUG lab. AVFoundation lives here, outside the features, as it does in
// MediaPlayback.
//
// ⚠️ IT DEPENDS ON NO LOCAL PACKAGE BUT CACHEKIT AND COREMODELS, for
// MediaPlayback's reason: AVFoundation needs Apple's system `MediaCore`
// framework, which a dependency on our `MediaCore` module would shadow.
// CacheKit and CoreModels depend on nothing (CoreModels holds `AudioFocus`,
// the floor MediaPlayback reads, #2373).
//
// `VoiceKitUI` (#2205) is the voice component every surface draws — the
// conversation's bubble and a voice post's caption, in three sizes. A
// separate library so VoiceKit stays UI-free; it adds DesignSystem, which
// depends on nothing either.
let package = Package(
    name: "VoiceKit",
    platforms: [.iOS("26.0")],
    products: [
        .library(name: "VoiceKit", targets: ["VoiceKit"]),
        .library(name: "VoiceKitUI", targets: ["VoiceKitUI"])
    ],
    dependencies: [
        .package(path: "../../Kit/LaunchArguments"),
        .package(path: "../CacheKit"),
        .package(path: "../../Kit/CoreModels"),
        .package(path: "../DesignSystem")
    ],
    targets: [
        .target(name: "VoiceKit", dependencies: ["LaunchArguments", "CacheKit", "CoreModels"]),
        .target(name: "VoiceKitUI", dependencies: ["LaunchArguments", "VoiceKit", "DesignSystem"]),
        .testTarget(name: "VoiceKitTests", dependencies: ["VoiceKit", "CacheKit"]),
        .testTarget(name: "VoiceKitUITests", dependencies: ["VoiceKitUI", "VoiceKit", "DesignSystem"])
    ]
)
