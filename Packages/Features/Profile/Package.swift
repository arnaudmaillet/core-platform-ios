// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Profile",
    platforms: [.iOS("26.0")],
    products: [
        .library(name: "Profile", targets: ["Profile"])
    ],
    dependencies: [
        .package(path: "../../Kit/LaunchArguments"),
        .package(path: "../../FeatureInterfaces/ProfileInterface"),
        .package(path: "../../FeatureInterfaces/AuthInterface"),
        .package(path: "../../FeatureInterfaces/FeedInterface"),
        .package(path: "../../FeatureInterfaces/MapsInterface"),
        // The profile's and the account's data, shared with Settings (#2382).
        .package(path: "../../FeatureInterfaces/ProfileData"),
        // Settings opens through its interface (#2382).
        .package(path: "../../FeatureInterfaces/SettingsInterface"),
        .package(path: "../../Kit/CoreContracts"),
        .package(path: "../../Kit/CoreModels"),
        .package(path: "../../Core/MediaCore"),
        .package(path: "../../Core/CoreNavigation"),
        .package(path: "../../Core/CoreNetworking"),
        .package(path: "../../Core/CoreStorage"),
        // The profile screens' last content on the device (#893).
        .package(path: "../../Core/CacheKit"),
        .package(path: "../../Core/LocalStore"),
        .package(path: "../../Core/DesignSystem"),
        // The hero page's shared mechanics (#1651).
        .package(path: "../../Core/HeroPage"),
        .package(path: "../../Core/MediaPlayback"),
        .package(path: "../../Core/PostGrid"),
        .package(path: "../../Core/ShareSheet"),
        // Tests only: the live-count suite drives the app's EntityStore
        // (#896); the target reaches it through PostGrid's card staking.
        .package(path: "../../Core/EntityStore"),
        // Tests only: the profile's pages are the post surfaces' grid (#1273,
        // #2379), built through `PostGridPages.make` — the real page, not a
        // stand-in.
        .package(path: "../../Core/PostSurfaces")
    ],
    targets: [
        .target(
            name: "Profile",
            dependencies: [
                // The profile's and the account's data, which Settings
                // reads too (#2382).
                "ProfileData",
                // The own profile's gear and Edit Profile's settings rows
                // open Settings through its interface (#2382).
                "SettingsInterface",
                "ProfileInterface",
                "AuthInterface",
                "FeedInterface",
                "MapsInterface",
                "CoreContracts",
                "CoreModels",
                // Its launch arguments, declared (#2374).
                "LaunchArguments",
                "MediaCore",
                .product(name: "MediaUI", package: "MediaCore"),
                "CoreNavigation", .product(name: "DebugDashboard", package: "CoreNavigation"),
                "CoreStorage",
                // The LocalStore's registration (#893).
                "CacheKit",
                "LocalStore",
                "DesignSystem",
                "HeroPage",
                // The shared player pool (`VideoPlaybackController`).
                "MediaPlayback",
                // ⚠️ The library target, not only the test one. `PostCounterReader`
                // lives in CoreNetworking and this feature reads its counters
                // through it — declared here because a warm derived-data tree
                // resolves a module the whole graph can see, and only a clean
                // build asks whether THIS target was entitled to it.
                "CoreNetworking",
                "PostGrid",
                // The share sheet the QR bubble and "..." → Share open — shared
                // with the place page since 5 October 2026.
                "ShareSheet"
            ]
        ),
        .testTarget(
            name: "ProfileTests",
            dependencies: [
                "LaunchArguments",
                "Profile",
                "ProfileData",
                // The feed's interface the suites' grid pages and hero
                // origins are built against.
                "FeedInterface",
                // `ProfileReference` / `ProfileLookup`, for the handle and
                // share-token lookup suite (#800).
                "ProfileInterface",
                "ShareSheet",
                "CoreNavigation",
                "CoreStorage",
                "CacheKit",
                "LocalStore",
                // The identity-ink suite reads `HeroInk`'s constants directly.
                "DesignSystem",
                "CoreNetworking",
                "PostGrid",
                "PostSurfaces",
                // The Storage suite drives a real coordinator and image pipeline,
                // and the video byte cache's namespaces.
                "MediaCore",
                .product(name: "MediaUI", package: "MediaCore"),
                "MediaPlayback",
                "EntityStore",
                .product(name: "CoreNetworkingMocks", package: "CoreNetworking")
            ]
        )
    ]
)
