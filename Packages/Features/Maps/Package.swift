// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Maps",
    platforms: [.iOS("26.0")],
    products: [
        .library(name: "Maps", targets: ["Maps"])
    ],
    dependencies: [
        .package(path: "../../Kit/LaunchArguments"),
        .package(path: "../../FeatureInterfaces/MapsInterface"),
        .package(path: "../../FeatureInterfaces/FeedInterface"),
        .package(path: "../../Kit/CoreContracts"),
        .package(path: "../../Kit/CoreModels"),
        .package(path: "../../Core/CoreNavigation"),
        .package(path: "../../Core/CoreNetworking"),
        .package(path: "../../Core/CoreStorage"),
        .package(path: "../../Core/DesignSystem"),
        .package(path: "../../Core/MediaCore"),
        .package(path: "../../Core/PostGrid"),
        .package(path: "../../Core/MediaPlayback"),
        .package(path: "../../Core/CacheKit"),
        .package(path: "../../Core/LocalStore"),
        .package(path: "../../Core/EmoteKit"),
        // The voice component (#2205): a voice pin's mark and the text
        // bubble's voice (#2208).
        .package(path: "../../Core/VoiceKit")
    ],
    targets: [
        .target(
            name: "Maps",
            dependencies: [
                "LaunchArguments",
                "MapsInterface",
                "FeedInterface",
                "CoreContracts",
                "CoreModels",
                "CoreNavigation",
                // `NetworkFailure`: the repository error keeps why a call
                // failed, so the screen can say "You're offline" (#794).
                "CoreNetworking",
                "CoreStorage",
                "DesignSystem",
                "MediaCore",
                "MediaPlayback",
                // `GalleryPost`: the text bubble's words (the text bubble, #2203).
                "PostGrid",
                // The flag palette lives in the device cache's UI assets class
                // (#971).
                "CacheKit",
                // The pins of the last viewports, on the device (#893).
                "LocalStore",
                // A text post's words on its Shop card, emotes animated (#1075).
                "EmoteKit",
                .product(name: "VoiceKitUI", package: "VoiceKit")
            ],
            // The world's borders (`CountryAtlas`), imported from Natural
            // Earth by `Scripts/import-country-borders.py`; the round flags
            // (`FlagPalette`), imported from circle-flags (MIT) by
            // `Scripts/import-circle-flags.py`, and their licence.
            resources: [
                .copy("Resources/countries.json"),
                .process("Resources/Flags/Flags.xcassets"),
                .copy("Resources/Flags/LICENSE")
            ]
        ),
        .testTarget(
            name: "MapsTests",
            dependencies: [
                "LaunchArguments",
                "Maps",
                "MapsInterface",
                // `AppRoute` / `PlaceLink`: a place's share link opens it (#985).
                "CoreNavigation",
                "DesignSystem",
                "CoreModels",
                "CoreNetworking",
                "CacheKit",
                "LocalStore",
                "PostGrid",
                .product(name: "VoiceKitUI", package: "VoiceKit"),
                .product(name: "CoreNetworkingMocks", package: "CoreNetworking")
            ]
        )
    ]
)
