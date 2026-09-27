// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "EmoteKit",
    platforms: [.iOS("26.0")],
    products: [
        .library(name: "EmoteKit", targets: ["EmoteKit"])
    ],
    dependencies: [
        // `AnimatedIconArt` / `AnimatedIconView`: the map's sprite-sheet player.
        // An emote plays through the SAME view the map's markers do, so a baked
        // emote and a baked map icon are one kind of thing on screen.
        .package(path: "../MediaCore"),
        // The house `:name:` stickers are StickerKit's dotLottie files.
        .package(path: "../StickerKit"),
        // Noto's animated emoji are Lottie JSON. The same declaration as
        // StickerKit's and Chat's, so all three resolve to one checkout.
        .package(url: "https://github.com/airbnb/lottie-ios.git", from: "4.5.0")
    ],
    targets: [
        .target(
            name: "EmoteKit",
            dependencies: [
                "MediaCore",
                "StickerKit",
                .product(name: "Lottie", package: "lottie-ios")
            ],
            // .copy, not .process: the Noto folder keeps its structure so the
            // catalogue can address it by subdirectory, and `.json.xz` is an
            // opaque archive no build rule should touch.
            resources: [
                .copy("Resources/Noto"),
                .copy("Resources/ACKNOWLEDGEMENTS.md")
            ]
        ),
        .testTarget(
            name: "EmoteKitTests",
            dependencies: [
                "EmoteKit",
                "MediaCore",
                .product(name: "Lottie", package: "lottie-ios")
            ]
        )
    ]
)
