// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Chat",
    platforms: [.iOS("26.0")],
    products: [
        .library(name: "Chat", targets: ["Chat"])
    ],
    dependencies: [
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
        .package(path: "../../Core/DesignSystem"),
        .package(path: "../../Core/EmoteKit"),
        .package(path: "../../Core/MediaCore"),
        // The conversation is drawn by Feed's text-post screen. The INTERFACE
        // only — features never import each other — the same edge Maps and
        // Profile already have.
        .package(path: "../../FeatureInterfaces/FeedInterface")
    ],
    targets: [
        .target(
            name: "Chat",
            dependencies: [
                "ChatInterface",
                "AuthInterface",
                "CoreContracts",
                "CoreModels",
                "CoreNavigation",
                "CoreNetworking",
                "CoreStorage",
                "DesignSystem",
                "EmoteKit",
                "FeedInterface",
                "MediaCore"
            ]
        ),
        .testTarget(
            name: "ChatTests",
            dependencies: [
                "Chat",
                "CoreNavigation",
                "CoreNetworking",
                "FeedInterface",
                .product(name: "CoreNetworkingMocks", package: "CoreNetworking")
            ]
        )
    ]
)
