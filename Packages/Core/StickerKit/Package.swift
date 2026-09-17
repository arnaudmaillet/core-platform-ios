// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "StickerKit",
    platforms: [.iOS("26.0")],
    products: [
        .library(name: "StickerKit", targets: ["StickerKit"])
    ],
    dependencies: [
        // Stickers are dotLottie (.lottie) files — a zipped bundle of Bodymovin
        // JSON — so a real player is required. The same declaration as Chat's,
        // so the two resolve to one checkout.
        .package(url: "https://github.com/airbnb/lottie-ios.git", from: "4.5.0")
    ],
    targets: [
        // Deliberately depends on NO local package. MediaPlayback does not
        // depend on this either: a compositor is handed sticker frames through
        // its `OverlayArtwork` protocol, so Lottie stays out of the media stack.
        .target(
            name: "StickerKit",
            dependencies: [.product(name: "Lottie", package: "lottie-ios")]
        ),
        .testTarget(
            name: "StickerKitTests",
            dependencies: ["StickerKit", .product(name: "Lottie", package: "lottie-ios")]
        )
    ]
)
