// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Upload",
    platforms: [.iOS("26.0")],
    products: [
        .library(name: "Upload", targets: ["Upload"])
    ],
    dependencies: [
        .package(path: "../../FeatureInterfaces/UploadInterface"),
        .package(path: "../../FeatureInterfaces/AuthInterface"),
        .package(path: "../../Kit/CoreContracts"),
        .package(path: "../../Kit/CoreModels"),
        .package(path: "../../Core/MediaCore"),
        .package(path: "../../Core/MediaPlayback"),
        .package(path: "../../Core/CoreNetworking"),
        .package(path: "../../Core/DesignSystem")
    ],
    targets: [
        .target(
            name: "Upload",
            dependencies: [
                "UploadInterface",
                "AuthInterface",
                "CoreContracts",
                "CoreModels",
                "MediaCore",
                "MediaPlayback",
                "DesignSystem"
            ]
        ),
        .testTarget(
            name: "UploadTests",
            dependencies: [
                "Upload",
                "CoreNetworking",
                .product(name: "CoreNetworkingMocks", package: "CoreNetworking")
            ]
        )
    ]
)
