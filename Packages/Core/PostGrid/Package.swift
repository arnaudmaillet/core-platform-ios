// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PostGrid",
    platforms: [.iOS("26.0")],
    products: [
        .library(name: "PostGrid", targets: ["PostGrid"])
    ],
    dependencies: [
        .package(path: "../../Kit/LaunchArguments"),
        .package(path: "../../Kit/CoreModels"),
        .package(path: "../MediaCore"),
        .package(path: "../MediaPlayback"),
        .package(path: "../DesignSystem"),
        // For `RevealStandInShaping` only — the stand-in card a reveal's
        // dismissal flies is a CARD, so it lives beside the cell it copies, and
        // the transition vocabulary it satisfies lives in CoreNavigation.
        // CoreNavigation depends on CoreModels alone, so this adds an edge and
        // no cycle.
        .package(path: "../CoreNavigation"),
        // For `PostCardStaking`: a card's like chip STAKES, and the wallet is
        // the store it spends from. CoreStorage depends on CoreModels alone.
        .package(path: "../CoreStorage"),
        // The cards' live like counts (#896).
        .package(path: "../EntityStore"),
        // Captions and text-post bodies animate their emotes.
        .package(path: "../EmoteKit"),
        // The voice component (#2205): a voice post's caption on cards,
        // tiles and history rows (#2208).
        .package(path: "../VoiceKit")
    ],
    targets: [
        .target(
            name: "PostGrid",
            dependencies: [
                "LaunchArguments",
                "CoreModels", "MediaCore", "MediaPlayback", "DesignSystem", "CoreNavigation",
                "CoreStorage", "EntityStore", "EmoteKit",
                .product(name: "VoiceKitUI", package: "VoiceKit")
            ]
        ),
        .testTarget(
            name: "PostGridTests",
            dependencies: [
                "PostGrid", "CoreStorage", "EntityStore", "EmoteKit", .product(name: "VoiceKitUI", package: "VoiceKit")
            ]
        )
    ]
)
