// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Maps",
    platforms: [.iOS("26.0")],
    products: [
        .library(name: "Maps", targets: ["Maps"])
    ],
    dependencies: [
        .package(path: "../../FeatureInterfaces/MapsInterface"),
        .package(path: "../../FeatureInterfaces/FeedInterface"),
        .package(path: "../../Kit/CoreContracts"),
        .package(path: "../../Kit/CoreModels"),
        .package(path: "../../Core/CoreNavigation"),
        .package(path: "../../Core/CoreNetworking"),
        .package(path: "../../Core/CoreStorage"),
        .package(path: "../../Core/DesignSystem"),
        .package(path: "../../Core/MediaCore"),
        .package(path: "../../Core/MediaPlayback")
    ],
    targets: [
        .target(
            name: "Maps",
            dependencies: [
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
                "MediaPlayback"
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
                "Maps",
                "MapsInterface",
                "DesignSystem",
                "CoreModels",
                "CoreNetworking",
                .product(name: "CoreNetworkingMocks", package: "CoreNetworking")
            ]
        )
    ]
)
