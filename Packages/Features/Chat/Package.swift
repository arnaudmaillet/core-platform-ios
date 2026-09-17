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
        // The conversation is drawn by Feed's text-post screen. The INTERFACE
        // only — features never import each other — the same edge Maps and
        // Profile already have.
        .package(path: "../../FeatureInterfaces/FeedInterface"),
        // The stickers the composer's favorite strip shows — files and
        // catalogue — shared with the upload editor, which is why they are not
        // Chat's resources any more.
        .package(path: "../../Core/StickerKit"),
        // The strip plays a tapped sticker itself. dotLottie (.lottie) is a
        // zipped bundle of Bodymovin JSON, so a real player is required —
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
                "FeedInterface",
                "MediaCore",
                "StickerKit",
                .product(name: "Lottie", package: "lottie-ios")
            ]
        ),
        .testTarget(
            name: "ChatTests",
            dependencies: [
                "Chat",
                "CoreNavigation",
                "CoreNetworking",
                "FeedInterface",
                .product(name: "CoreNetworkingMocks", package: "CoreNetworking")
            ]
        )
    ]
)
