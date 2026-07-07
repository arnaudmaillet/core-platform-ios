// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Notifications",
    platforms: [.iOS("26.0")],
    products: [
        .library(name: "Notifications", targets: ["Notifications"])
    ],
    dependencies: [
        .package(path: "../../FeatureInterfaces/NotificationsInterface"),
        .package(path: "../../FeatureInterfaces/AuthInterface"),
        .package(path: "../../Kit/CoreContracts"),
        .package(path: "../../Kit/CoreModels"),
        .package(path: "../../Core/CoreNavigation"),
        .package(path: "../../Core/CoreNetworking"),
        .package(path: "../../Core/DesignSystem")
    ],
    targets: [
        .target(
            name: "Notifications",
            dependencies: [
                "NotificationsInterface",
                "AuthInterface",
                "CoreContracts",
                "CoreModels",
                "CoreNavigation",
                "DesignSystem"
            ]
        ),
        .testTarget(
            name: "NotificationsTests",
            dependencies: [
                "Notifications",
                "CoreNavigation",
                "CoreNetworking",
                .product(name: "CoreNetworkingMocks", package: "CoreNetworking")
            ]
        )
    ]
)
