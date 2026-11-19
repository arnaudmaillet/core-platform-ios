// swift-tools-version: 6.0
import PackageDescription

// Settings and Account (#2382, stage 3): every screen the own profile's gear
// opens, their view models, and the device caches only they read. It was a
// target of the Profile package; the profile and the app now open it through
// SettingsInterface, and the app's composition root builds it
// (`SettingsAssembly`) with typed dependencies.
//
// The data it shares with the profile (the repositories, the capability
// protocols, the relationship list's cell and model, the field editor) is
// ProfileData's: a feature never depends on another feature.
let package = Package(
    name: "Settings",
    platforms: [.iOS("26.0")],
    products: [
        .library(name: "Settings", targets: ["Settings"])
    ],
    dependencies: [
        .package(path: "../../Kit/CoreContracts"),
        .package(path: "../../Kit/CoreModels"),
        .package(path: "../../Kit/LaunchArguments"),
        .package(path: "../../FeatureInterfaces/AuthInterface"),
        .package(path: "../../FeatureInterfaces/ProfileData"),
        .package(path: "../../FeatureInterfaces/ProfileInterface"),
        .package(path: "../../FeatureInterfaces/SettingsInterface"),
        // App Lock and the appearance (#2383).
        .package(path: "../../Core/AppPreferences"),
        // Settings → Storage measures and clears the coordinated caches
        // (#894) through the app's `CacheCoordinator`.
        .package(path: "../../Core/CacheKit"),
        .package(path: "../../Core/CoreNavigation"),
        .package(path: "../../Core/CoreNetworking"),
        .package(path: "../../Core/CoreStorage"),
        .package(path: "../../Core/DesignSystem"),
        .package(path: "../../Core/EmoteKit"),
        .package(path: "../../Core/LocalStore"),
        .package(path: "../../Core/MediaCore"),
        // Settings → App Preferences measures and clears the video cache it
        // names (`VideoSourceCache`).
        .package(path: "../../Core/MediaPlayback"),
        .package(path: "../../Core/PostGrid")
    ],
    targets: [
        .target(
            name: "Settings",
            dependencies: [
                "CoreModels",
                // Its launch arguments, declared (#2374).
                "LaunchArguments",
                "AuthInterface",
                "ProfileData",
                "ProfileInterface",
                "SettingsInterface",
                "AppPreferences",
                "CacheKit",
                "CoreNavigation", .product(name: "DebugDashboard", package: "CoreNavigation"),
                "CoreNetworking",
                "CoreStorage",
                "DesignSystem",
                "EmoteKit",
                "LocalStore",
                "MediaCore",
                .product(name: "MediaUI", package: "MediaCore"),
                "MediaPlayback",
                "PostGrid"
            ],
            // Settings → Legal and About → Acknowledgements (#1128): the
            // third-party licences the app ships under.
            resources: [.process("Resources/Acknowledgements.json")]
        ),
        .testTarget(
            name: "SettingsTests",
            dependencies: [
                "Settings",
                "SettingsInterface",
                "ProfileData",
                "AppPreferences",
                "AuthInterface",
                "CacheKit",
                "CoreContracts",
                "CoreModels",
                "CoreNetworking",
                .product(name: "CoreNetworkingMocks", package: "CoreNetworking"),
                "CoreStorage",
                "DesignSystem",
                "LocalStore",
                "MediaCore",
                .product(name: "MediaUI", package: "MediaCore"),
                "MediaPlayback",
                "PostGrid"
            ]
        )
    ]
)
