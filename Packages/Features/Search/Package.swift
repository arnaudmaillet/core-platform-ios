// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Search",
    platforms: [.iOS("26.0")],
    products: [
        .library(name: "Search", targets: ["Search"])
    ],
    dependencies: [
        .package(path: "../../FeatureInterfaces/AuthInterface"),
        .package(path: "../../FeatureInterfaces/SearchInterface"),
        .package(path: "../../Kit/CoreContracts"),
        .package(path: "../../Kit/CoreModels"),
        .package(path: "../../Core/CoreNavigation"),
        .package(path: "../../Core/CoreNetworking"),
        .package(path: "../../Core/CoreStorage"),
        .package(path: "../../Core/DesignSystem"),
        .package(path: "../../Core/MediaCore"),
        .package(path: "../../Core/LocalStore")
    ],
    targets: [
        .target(
            name: "Search",
            dependencies: [
                // `ViewerScoped`: the person rows' follow state is the
                // viewer's, and drops on a viewer change (#892).
                "AuthInterface",
                "SearchInterface",
                "CoreContracts",
                "CoreModels",
                "CoreNavigation",
                // `NetworkFailure`: the repository error keeps why a call
                // failed, so the screen can say "You're offline" (#794).
                "CoreNetworking",
                "CoreStorage",
                "DesignSystem",
                "MediaCore",
                // The resting screen's trending people, on the device (#893).
                "LocalStore"
            ]
        ),
        .testTarget(
            name: "SearchTests",
            dependencies: [
                "Search",
                "AuthInterface",
                "CoreNavigation",
                "CoreNetworking",
                "CoreStorage",
                "MediaCore",
                "LocalStore",
                .product(name: "CoreNetworkingMocks", package: "CoreNetworking")
            ]
        )
    ]
)
