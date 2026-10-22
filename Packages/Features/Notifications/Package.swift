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
        .package(path: "../../Core/DesignSystem"),
        .package(path: "../../Core/MediaCore"),
        // The drawer's last notifications on the device (#897).
        .package(path: "../../Core/CacheKit"),
        .package(path: "../../Core/LocalStore")
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
                "CoreNetworking",
                "DesignSystem",
                "MediaCore",
                "CacheKit",
                "LocalStore"
            ]
        ),
        .testTarget(
            name: "NotificationsTests",
            dependencies: [
                "Notifications",
                // `.notificationsReadDidChange` (#1572).
                "NotificationsInterface",
                "AuthInterface",
                "CoreNavigation",
                "CoreNetworking",
                // `NotificationsLocalCacheTests` opens a store in a temporary folder.
                "CacheKit",
                "LocalStore",
                .product(name: "CoreNetworkingMocks", package: "CoreNetworking")
            ]
        )
    ]
)
