// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Feed",
    platforms: [.iOS("26.0")],
    products: [
        .library(name: "Feed", targets: ["Feed"])
    ],
    dependencies: [
        .package(path: "../../FeatureInterfaces/FeedInterface"),
        .package(path: "../../FeatureInterfaces/AuthInterface"),
        .package(path: "../../FeatureInterfaces/ProfileInterface"),
        .package(path: "../../Kit/CoreContracts"),
        .package(path: "../../Kit/CoreModels"),
        .package(path: "../../Core/MediaCore"),
        .package(path: "../../Core/MediaPlayback"),
        .package(path: "../../Core/CoreNavigation"),
        .package(path: "../../Core/CoreNetworking"),
        .package(path: "../../Core/CoreRealtime"),
        .package(path: "../../Core/CoreStorage"),
        .package(path: "../../Core/DesignSystem"),
        .package(path: "../../Core/EmoteKit"),
        .package(path: "../../Core/PostGrid"),
        .package(path: "../../Core/ShareSheet")
    ],
    targets: [
        .target(
            name: "Feed",
            dependencies: [
                "FeedInterface",
                "AuthInterface",
                "ProfileInterface",
                "CoreContracts",
                "CoreModels",
                "MediaCore",
                "MediaPlayback",
                "CoreNavigation",
                "CoreRealtime",
                "CoreStorage",
                "DesignSystem",
                "EmoteKit",
                // ⚠️ The library target, not only the test one. `PostCounterReader`
                // lives in CoreNetworking and this feature reads its counters
                // through it — declared here because a warm derived-data tree
                // resolves a module the whole graph can see, and only a clean
                // build asks whether THIS target was entitled to it.
                "CoreNetworking",
                "PostGrid",
                // The place page's QR bubble opens the profile's share sheet.
                "ShareSheet"
            ]
        ),
        .testTarget(
            name: "FeedTests",
            dependencies: [
                "Feed",
                "DesignSystem",
                "EmoteKit",
                "CoreNavigation",
                "CoreNetworking",
                "CoreStorage",
                "PostGrid",
                .product(name: "CoreNetworkingMocks", package: "CoreNetworking"),
                .product(name: "CoreRealtimeMocks", package: "CoreRealtime")
            ]
        )
    ]
)
