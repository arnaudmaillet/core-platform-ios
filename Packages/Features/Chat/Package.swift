// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Chat",
    platforms: [.iOS("26.0")],
    products: [
        .library(name: "Chat", targets: ["Chat"])
    ],
    dependencies: [
        .package(path: "../../FeatureInterfaces/ChatInterface"),
        .package(path: "../../FeatureInterfaces/AuthInterface"),
        .package(path: "../../Kit/CoreContracts"),
        .package(path: "../../Kit/CoreModels"),
        .package(path: "../../Core/CoreNavigation"),
        .package(path: "../../Core/CoreNetworking"),
        // The device-local search history the global search screen writes to; the
        // inbox reads and writes the SAME store, so a query typed in one is
        // recent in the other.
        .package(path: "../../Core/CoreStorage"),
        .package(path: "../../Core/DesignSystem"),
        .package(path: "../../Core/MediaCore"),
        // Renders the composer's favorite-sticker strip. dotLottie (.lottie)
        // is a zipped bundle of Bodymovin JSON, so a real player is required —
        // there is no UIImage path for it.
        .package(url: "https://github.com/airbnb/lottie-ios.git", from: "4.5.0")
    ],
    targets: [
        .target(
            name: "Chat",
            dependencies: [
                "ChatInterface",
                "AuthInterface",
                "CoreContracts",
                "CoreModels",
                "CoreNavigation",
                "CoreStorage",
                "DesignSystem",
                "MediaCore",
                .product(name: "Lottie", package: "lottie-ios")
            ],
            // .copy, not .process: the sticker folder keeps its structure in
            // the bundle so the catalog can address it by subdirectory, and
            // .lottie is an opaque archive no build rule should touch.
            resources: [.copy("Resources/Stickers")]
        ),
        .testTarget(
            name: "ChatTests",
            dependencies: [
                "Chat",
                "CoreNavigation",
                "CoreNetworking",
                .product(name: "CoreNetworkingMocks", package: "CoreNetworking")
            ]
        )
    ]
)
