// swift-tools-version: 6.0
import PackageDescription

// The rows of a thread (#2380, epic #2366): a comment's row and its model, the
// conversation's row cell with its media and voice, the row's context menu
// and effect, and the conversation's delivery and media values. The feed's
// comments, the post page, For You's preview and the conversation all draw
// them; they lived in Feed, so every one of those paid for Feed. A Core
// package: no interface, no feature.
let package = Package(
    name: "ThreadKit",
    platforms: [.iOS("26.0")],
    products: [
        .library(name: "ThreadKit", targets: ["ThreadKit"])
    ],
    dependencies: [
        .package(path: "../../Kit/CoreModels"),
        .package(path: "../DesignSystem"),
        .package(path: "../MediaCore"),
        .package(path: "../EmoteKit"),
        // `PostEmbedView`: a comment carries a post's embed.
        .package(path: "../PostGrid"),
        // The voice comment's and the voice message's component.
        .package(path: "../VoiceKit")
    ],
    targets: [
        .target(
            name: "ThreadKit",
            dependencies: [
                "CoreModels", "DesignSystem", "MediaCore", "EmoteKit", "PostGrid",
                .product(name: "VoiceKitUI", package: "VoiceKit")
            ]
        ),
        .testTarget(name: "ThreadKitTests", dependencies: ["ThreadKit"])
    ]
)
