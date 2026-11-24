// swift-tools-version: 6.0
import PackageDescription

// The place page (#2381, epic #2366): a country's or a city's page, from the
// map (inserted under the cluster feed, uncovered by its downward close) or
// alone (a shared place link). It lived in Feed; it is a Maps screen built
// on the post surfaces (`PostSurfaces`).
//
// It opens posts in the feed's reader through `FeedInterface`, never Feed;
// Maps and the app shell reach it through `PlaceInterface`.
let package = Package(
    name: "Place",
    platforms: [.iOS("26.0")],
    products: [
        .library(name: "Place", targets: ["Place"])
    ],
    dependencies: [
        .package(path: "../../Kit/LaunchArguments"),
        .package(path: "../../Kit/CoreContracts"),
        .package(path: "../../Kit/CoreModels"),
        .package(path: "../../FeatureInterfaces/PlaceInterface"),
        .package(path: "../../FeatureInterfaces/FeedInterface"),
        .package(path: "../../Core/MediaCore"),
        .package(path: "../../Core/MediaPlayback"),
        .package(path: "../../Core/CoreNavigation"),
        .package(path: "../../Core/CoreNetworking"),
        .package(path: "../../Core/CoreStorage"),
        .package(path: "../../Core/EntityStore"),
        .package(path: "../../Core/DesignSystem"),
        .package(path: "../../Core/PostGrid"),
        .package(path: "../../Core/PostSurfaces"),
        .package(path: "../../Core/ShareSheet"),
        .package(path: "../../Core/HeroPage")
    ],
    targets: [
        .target(
            name: "Place",
            dependencies: [
                "LaunchArguments", "CoreContracts", "CoreModels", "PlaceInterface", "FeedInterface",
                "MediaCore", "MediaPlayback", "CoreNavigation", .product(name: "Transitions", package: "CoreNavigation"), "CoreNetworking", "CoreStorage", "EntityStore",
                "DesignSystem", "PostGrid", "PostSurfaces", "ShareSheet", "HeroPage"
            ]
        ),
        // The place page's suites, which moved with it from Feed.
        .testTarget(
            name: "PlaceTests",
            dependencies: [
                // Mock media (#2516): the offline fetchers the suites draw with.
                .product(name: "MediaCoreFixtures", package: "MediaCore"),
                "Place", "PlaceInterface", "CoreContracts", "CoreModels", "CoreNavigation", .product(name: "Transitions", package: "CoreNavigation"), "CoreNetworking",
                .product(name: "CoreNetworkingMocks", package: "CoreNetworking"),
                "CoreStorage", "DesignSystem", "HeroPage", "MediaCore", "MediaPlayback", "PostGrid", "PostSurfaces"
            ]
        )
    ]
)
