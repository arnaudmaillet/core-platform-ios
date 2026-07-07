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
        .package(path: "../../Core/DesignSystem")
    ],
    targets: [
        .target(
            name: "Search",
            dependencies: [
                "SearchInterface",
                "CoreContracts",
                "CoreModels",
                "CoreNavigation",
                "DesignSystem"
            ]
        ),
        .testTarget(
            name: "SearchTests",
            dependencies: [
                "Search",
                "CoreNavigation",
                "CoreNetworking",
                .product(name: "CoreNetworkingMocks", package: "CoreNetworking")
            ]
        )
    ]
)
