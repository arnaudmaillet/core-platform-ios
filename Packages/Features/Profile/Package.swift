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
        .package(path: "../../Kit/CoreContracts"),
        .package(path: "../../Kit/CoreModels"),
        .package(path: "../../Core/MediaCore"),
        .package(path: "../../Core/CoreNavigation"),
        .package(path: "../../Core/CoreNetworking"),
        .package(path: "../../Core/CoreStorage"),
        // The profile screens' last content on the device (#893), and
        // Settings → Storage's coordinated caches (#894).
        .package(path: "../../Core/CacheKit"),
        .package(path: "../../Core/LocalStore"),
        .package(path: "../../Core/DesignSystem"),
        // The hero page's shared mechanics (#1651).
        .package(path: "../../Core/HeroPage"),
        .package(path: "../../Core/EmoteKit"),
        .package(path: "../../Core/MediaPlayback"),
        .package(path: "../../Core/PostGrid"),
        .package(path: "../../Core/ShareSheet"),
        // Tests only: the live-count suite drives the app's EntityStore
        // (#896); the target reaches it through PostGrid's card staking.
        .package(path: "../../Core/EntityStore"),
        // Tests only: the profile's pages are For You's grid (#1273), built
        // through `PostGridPages.make` — the real page, not a stand-in.
        .package(path: "../Feed")
    ],
    targets: [
        // Settings and Account, with the data layer they share with the
        // profile (#2382, stage 1): about 118 files that never reference the
        // profile's screens, split from them so the boundary is the
        // compiler's. Declarations the profile reads are `package`. Stage 3
        // makes this a feature package of its own.
        .target(
            name: "ProfileSettings",
            dependencies: [
                "ProfileInterface",
                "AuthInterface",
                "FeedInterface",
                "MapsInterface",
                "CoreContracts",
                "CoreModels",
                "MediaCore",
                "CoreNavigation",
                "CoreStorage",
                // The LocalStore's registration (#893), and Settings → Storage
                // measuring and clearing the coordinated caches (images, #894)
                // through the app's `CacheCoordinator`.
                "CacheKit",
                "LocalStore",
                "DesignSystem",
                "HeroPage",
                "EmoteKit",
                // Settings → App Preferences measures and clears the video
                // cache it names (`VideoSourceCache`); the builder already
                // imported it through PostGrid, which only a warm tree allows.
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
            ],
            // Settings → Legal and About → Acknowledgements (#1128): the
            // third-party licences the app ships under.
            resources: [.process("Resources/Acknowledgements.json")]
        ),
        .target(
            name: "Profile",
            dependencies: [
                // Settings, Account and the profile's data (#2382, stage 1):
                // a target of its own, which the profile screens build on.
                "ProfileSettings",
                "ProfileInterface",
                "AuthInterface",
                "FeedInterface",
                "MapsInterface",
                "CoreContracts",
                "CoreModels",
                "MediaCore",
                "CoreNavigation",
                "CoreStorage",
                // The LocalStore's registration (#893), and Settings → Storage
                // measuring and clearing the coordinated caches (images, #894)
                // through the app's `CacheCoordinator`.
                "CacheKit",
                "LocalStore",
                "DesignSystem",
                "HeroPage",
                "EmoteKit",
                // Settings → App Preferences measures and clears the video
                // cache it names (`VideoSourceCache`); the builder already
                // imported it through PostGrid, which only a warm tree allows.
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
                "ProfileSettings",
                "Feed",
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
                // The Storage suite drives a real coordinator and image pipeline,
                // and the video byte cache's namespaces.
                "MediaCore",
                "MediaPlayback",
                "EntityStore",
                .product(name: "CoreNetworkingMocks", package: "CoreNetworking")
            ]
        )
    ]
)
