// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Chat",
    platforms: [.iOS("26.0")],
    products: [
        .library(name: "Chat", targets: ["Chat"])
    ],
    dependencies: [
        .package(path: "../../Kit/LaunchArguments"),
        .package(path: "../../FeatureInterfaces/ChatInterface"),
        .package(path: "../../FeatureInterfaces/AuthInterface"),
        .package(path: "../../Kit/CoreContracts"),
        .package(path: "../../Kit/CoreModels"),
        .package(path: "../../Core/CoreNavigation"),
        .package(path: "../../Core/CoreNetworking"),
        // The device-local search history the global search screen writes to; the
        // inbox reads and writes the SAME store, so a query typed in one is
        // recent in the other.
        .package(path: "../../Core/CoreStorage"),
        // The inbox and the last conversations on the device (#897).
        .package(path: "../../Core/CacheKit"),
        .package(path: "../../Core/LocalStore"),
        .package(path: "../../Core/DesignSystem"),
        .package(path: "../../Core/EmoteKit"),
        .package(path: "../../Core/MediaCore"),
        // Where the viewer stands with each person, the app's one copy
        // (#2049): the rows' relation marks read and write it.
        .package(path: "../../Core/EntityStore"),
        // Voice messages (#2103): a sent take is kept as its message's audio.
        .package(path: "../../Core/VoiceKit"),
        // The conversation is drawn by Feed's text-post screen. The INTERFACE
        // only — features never import each other — the same edge Maps and
        // Profile already have.
        .package(path: "../../FeatureInterfaces/FeedInterface"),
        // A group's and a channel's info screens are the profile's and the
        // place's page (#2237): the hero header, the lists behind its
        // counters, the page under it — a Core package, no feature.
        .package(path: "../../Core/HeroPage"),
        // The Posts page's types (`GalleryPost`, `PostCardStaking`).
        .package(path: "../../Core/PostGrid"),
        // The tests' shared waits (#2389).
        .package(path: "../../Tools/TestSupport")
    ],
    targets: [
        .target(
            name: "Chat",
            dependencies: [
                "LaunchArguments",
                "ChatInterface",
                "AuthInterface",
                "CoreContracts",
                "CoreModels",
                "CoreNavigation",
                "CoreNetworking",
                "CoreStorage",
                "CacheKit",
                "LocalStore",
                "DesignSystem",
                "EmoteKit",
                "FeedInterface",
                "MediaCore",
                "EntityStore",
                "VoiceKit",
                "HeroPage",
                "PostGrid"
            ]
        ),
        .testTarget(
            name: "ChatTests",
            dependencies: [
                "Chat",
                "TestSupport",
                "CoreNavigation",
                "CoreNetworking",
                "FeedInterface",
                // `InboxRelationMarkTests` (#2049).
                "EntityStore",
                // `ChatMediaTests` builds an uploader and a transport (#681).
                "MediaCore",
                // `ChatLocalCacheTests` opens a store in a temporary folder.
                "CacheKit",
                "LocalStore",
                // `ChatMediaTests` keeps a sent take in a voice cache (#2103).
                "VoiceKit",
                // The info screens' header and lists (#2237).
                "HeroPage",
                .product(name: "CoreNetworkingMocks", package: "CoreNetworking")
            ]
        )
    ]
)
