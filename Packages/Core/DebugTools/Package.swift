// swift-tools-version: 6.2
import PackageDescription

// The app's debug tools (#2386, epic #2366): the audits that print a frame's
// measures, the labs that tune a material live, the traces and the benches.
// Every source is `#if DEBUG`, so a Release build compiles this module empty;
// they lived in App, interleaved with the shell's production files. A Core
// package: it reads Core's types and no feature's.
//
// ⚠️ THE APP'S ISOLATION, KEPT. These files were written under App's
// `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` and approachable concurrency;
// the target says the same (tools 6.2), so their meaning did not change with
// the move.
let package = Package(
    name: "DebugTools",
    platforms: [.iOS("26.0")],
    products: [
        .library(name: "DebugTools", targets: ["DebugTools"])
    ],
    dependencies: [
        .package(path: "../../Kit/CoreModels"),
        .package(path: "../DesignSystem"),
        .package(path: "../CoreNavigation"),
        .package(path: "../MediaPlayback"),
        .package(path: "../PostGrid"),
        // `NetworkConditionsMenu` flips the mock transport's conditions.
        .package(path: "../CoreNetworking"),
        // The dashboard's caches and resets, and its voice preferences.
        .package(path: "../CacheKit"),
        .package(path: "../LocalStore"),
        .package(path: "../VoiceKit")
    ],
    targets: [
        .target(
            name: "DebugTools",
            dependencies: [
                "CoreModels", "DesignSystem", "CoreNavigation", "MediaPlayback", "PostGrid",
                .product(name: "CoreNetworkingMocks", package: "CoreNetworking"),
                "CacheKit", "LocalStore",
                .product(name: "VoiceKitUI", package: "VoiceKit")
            ],
            swiftSettings: [
                .defaultIsolation(MainActor.self),
                .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
                .enableUpcomingFeature("InferIsolatedConformances")
            ]
        )
    ]
)
