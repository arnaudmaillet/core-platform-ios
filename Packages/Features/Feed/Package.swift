// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Feed",
    platforms: [.iOS("26.5")],
    products: [
        .library(name: "Feed", targets: ["Feed"])
    ],
    dependencies: [
        .package(path: "../../FeatureInterfaces/FeedInterface"),
        .package(path: "../../FeatureInterfaces/AuthInterface"),
        .package(path: "../../Kit/CoreContracts"),
        .package(path: "../../Kit/CoreModels"),
        .package(path: "../../Core/CoreMedia"),
        .package(path: "../../Core/CoreNetworking"),
        .package(path: "../../Core/CoreRealtime"),
        .package(path: "../../Core/CoreStorage"),
        .package(path: "../../Core/DesignSystem")
    ],
    targets: [
        .target(
            name: "Feed",
            dependencies: [
                "FeedInterface",
                "AuthInterface",
                "CoreContracts",
                "CoreModels",
                "CoreMedia",
                "CoreRealtime",
                "CoreStorage",
                "DesignSystem"
            ]
        ),
        .testTarget(
            name: "FeedTests",
            dependencies: [
                "Feed",
                "CoreNetworking",
                .product(name: "CoreNetworkingMocks", package: "CoreNetworking"),
                .product(name: "CoreRealtimeMocks", package: "CoreRealtime")
            ]
        )
    ]
)
