// swift-tools-version: 6.0
import PackageDescription

// The rows of a thread (#2380, epic #2366): a comment's row and its model, the
// conversation's row cell with its media and voice, the row's context menu
// and effect, and the conversation's delivery and media values. The feed's
// comments, the post page, For You's preview and the conversation all draw
// them; they lived in Feed, so every one of those paid for Feed. A Core
// package: no interface, no feature.
//
// And the chrome built around them (#2380, 2a): the comments' input bar, its
// voice composer, the action column, the comments' layout and frost, the
// footer toolbar's widths, the stake button.
let package = Package(
    name: "ThreadKit",
    platforms: [.iOS("26.0")],
    products: [
        .library(name: "ThreadKit", targets: ["ThreadKit"])
    ],
    dependencies: [
        .package(path: "../../Kit/CoreModels"),
        // The composer's QA switches (`LaunchArgument`).
        .package(path: "../../Kit/LaunchArguments"),
        .package(path: "../DesignSystem"),
        .package(path: "../MediaCore"),
        .package(path: "../EmoteKit"),
        // `PostEmbedView`: a comment carries a post's embed.
        .package(path: "../PostGrid"),
        // The voice comment's and the voice message's component.
        .package(path: "../VoiceKit"),
        // `MemberGates`: the composer and the stake button ask whether the
        // viewer is a member.
        .package(path: "../CoreNavigation"),
        // `WalletStore.Policy`: the composer's stake amounts.
        .package(path: "../CoreStorage")
    ],
    targets: [
        .target(
            name: "ThreadKit",
            dependencies: [
                "CoreModels", "LaunchArguments", "DesignSystem", "MediaCore", .product(name: "MediaUI", package: "MediaCore"),
                "EmoteKit", "PostGrid", "VoiceKit", .product(name: "VoiceKitUI", package: "VoiceKit"),
                "CoreNavigation", "CoreStorage"
            ]
        ),
        .testTarget(
            name: "ThreadKitTests",
            dependencies: ["ThreadKit", "CoreModels", "DesignSystem", "CoreNavigation"]
        )
    ]
)
