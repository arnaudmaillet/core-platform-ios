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
                "DesignSystem",
                "MediaCore",
                "MediaPlayback"
            ]
        ),
        .testTarget(
            name: "MapsTests",
            dependencies: [
                "Maps",
                "CoreModels",
                "CoreNetworking",
                .product(name: "CoreNetworkingMocks", package: "CoreNetworking")
            ]
        )
    ]
)
