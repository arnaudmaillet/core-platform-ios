// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Upload",
    platforms: [.iOS("26.0")],
    products: [
        .library(name: "Upload", targets: ["Upload"])
    ],
    dependencies: [
        .package(path: "../../FeatureInterfaces/AuthInterface"),
        // The Text Post screen is drawn by Feed. The INTERFACE only — Upload
        // hands it a publisher, the way Chat hands it a thread driver.
        .package(path: "../../FeatureInterfaces/FeedInterface"),
        .package(path: "../../Kit/CoreContracts"),
        .package(path: "../../Kit/CoreModels"),
        // The picker wears the app's chrome: the segmented strip in its bottom
        // toolbar, the spacing scale, the empty states.
        .package(path: "../../Core/DesignSystem"),
        .package(path: "../../Core/MediaCore"),
        .package(path: "../../Core/MediaPlayback"),
        .package(path: "../../Core/CoreNetworking")
    ],
    targets: [
        .target(
            name: "Upload",
            dependencies: [
                "AuthInterface",
                "FeedInterface",
                "CoreContracts",
                "CoreModels",
                "DesignSystem",
                "MediaCore",
                "MediaPlayback"
            ]
        ),
        .testTarget(
            name: "UploadTests",
            dependencies: [
                "Upload",
                "FeedInterface",
                "CoreNetworking",
                .product(name: "CoreNetworkingMocks", package: "CoreNetworking")
            ]
        )
    ]
)
