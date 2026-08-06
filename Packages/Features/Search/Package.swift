// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Search",
    platforms: [.iOS("26.0")],
    products: [
        .library(name: "Search", targets: ["Search"])
    ],
    dependencies: [
        .package(path: "../../FeatureInterfaces/SearchInterface"),
        .package(path: "../../Kit/CoreContracts"),
        .package(path: "../../Kit/CoreModels"),
        .package(path: "../../Core/CoreNavigation"),
        .package(path: "../../Core/CoreNetworking"),
        .package(path: "../../Core/CoreStorage"),
        .package(path: "../../Core/DesignSystem"),
        .package(path: "../../Core/MediaCore")
    ],
    targets: [
        .target(
            name: "Search",
            dependencies: [
                "SearchInterface",
                "CoreContracts",
                "CoreModels",
                "CoreNavigation",
                "CoreStorage",
                "DesignSystem",
                "MediaCore"
            ]
        ),
        .testTarget(
            name: "SearchTests",
            dependencies: [
                "Search",
                "CoreNavigation",
                "CoreNetworking",
                "CoreStorage",
                .product(name: "CoreNetworkingMocks", package: "CoreNetworking")
            ]
        )
    ]
)
