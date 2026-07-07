// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Profile",
    platforms: [.iOS("26.5")],
    products: [
        .library(name: "Profile", targets: ["Profile"])
    ],
    dependencies: [
        .package(path: "../../FeatureInterfaces/ProfileInterface"),
        .package(path: "../../FeatureInterfaces/AuthInterface"),
        .package(path: "../../Kit/CoreContracts"),
        .package(path: "../../Kit/CoreModels"),
        .package(path: "../../Core/CoreMedia"),
        .package(path: "../../Core/CoreNetworking"),
        .package(path: "../../Core/DesignSystem")
    ],
    targets: [
        .target(
            name: "Profile",
            dependencies: [
                "ProfileInterface",
                "AuthInterface",
                "CoreContracts",
                "CoreModels",
                "CoreMedia",
                "DesignSystem"
            ]
        ),
        .testTarget(
            name: "ProfileTests",
            dependencies: [
                "Profile",
                "CoreNetworking",
                .product(name: "CoreNetworkingMocks", package: "CoreNetworking")
            ]
        )
    ]
)
