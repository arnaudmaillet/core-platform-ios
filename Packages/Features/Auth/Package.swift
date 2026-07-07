// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Auth",
    platforms: [.iOS("26.0")],
    products: [
        .library(name: "Auth", targets: ["Auth"])
    ],
    dependencies: [
        .package(path: "../../FeatureInterfaces/AuthInterface"),
        .package(path: "../../Kit/CoreContracts"),
        .package(path: "../../Kit/CoreModels"),
        .package(path: "../../Core/CoreNetworking"),
        .package(path: "../../Core/CoreStorage"),
        .package(path: "../../Core/DesignSystem")
    ],
    targets: [
        .target(
            name: "Auth",
            dependencies: [
                "AuthInterface",
                "CoreContracts",
                "CoreModels",
                "CoreNetworking",
                "CoreStorage",
                "DesignSystem"
            ]
        ),
        .testTarget(
            name: "AuthTests",
            dependencies: [
                "Auth",
                .product(name: "CoreNetworkingMocks", package: "CoreNetworking")
            ]
        )
    ]
)
