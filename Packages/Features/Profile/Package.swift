// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Profile",
    platforms: [.iOS("26.0")],
    products: [
        .library(name: "Profile", targets: ["Profile"])
    ],
    dependencies: [
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
        .package(path: "../../Core/DesignSystem"),
        .package(path: "../../Core/EmoteKit"),
        .package(path: "../../Core/MediaPlayback"),
        .package(path: "../../Core/PostGrid")
    ],
    targets: [
        .target(
            name: "Profile",
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
                "DesignSystem",
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
                "PostGrid"
            ]
        ),
        .testTarget(
            name: "ProfileTests",
            dependencies: [
                "Profile",
                "CoreNavigation",
                "CoreStorage",
                // The identity-ink suite reads `HeroInk`'s constants directly.
                "DesignSystem",
                "CoreNetworking",
                "PostGrid",
                .product(name: "CoreNetworkingMocks", package: "CoreNetworking")
            ]
        )
    ]
)
