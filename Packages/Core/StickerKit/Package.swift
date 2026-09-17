// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "StickerKit",
    platforms: [.iOS("26.0")],
    products: [
        .library(name: "StickerKit", targets: ["StickerKit"])
    ],
    dependencies: [
        // For `OverlayArtwork` only: baked sticker frames are handed to the
        // compositor through that protocol. The edge points THIS way on purpose
        // — MediaPlayback depends on no local package, and it must never learn
        // about Lottie, which renders on the main actor alone.
        .package(path: "../MediaPlayback"),
        // Stickers are dotLottie (.lottie) files — a zipped bundle of Bodymovin
        // JSON — so a real player is required. The same declaration as Chat's,
        // so the two resolve to one checkout.
        .package(url: "https://github.com/airbnb/lottie-ios.git", from: "4.5.0")
    ],
    targets: [
        .target(
            name: "StickerKit",
            dependencies: [
                "MediaPlayback",
                .product(name: "Lottie", package: "lottie-ios")
            ],
            // .copy, not .process: the sticker folder keeps its structure in
            // the bundle so the catalogue can address it by subdirectory, and
            // .lottie is an opaque archive no build rule should touch.
            resources: [.copy("Resources/Stickers")]
        ),
        .testTarget(
            name: "StickerKitTests",
            dependencies: [
                "StickerKit",
                "MediaPlayback",
                .product(name: "Lottie", package: "lottie-ios")
            ]
        )
    ]
)
