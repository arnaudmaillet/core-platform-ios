// swift-tools-version: 6.0
import PackageDescription

/// The post surfaces (#2379, epic #2366): the grid and list pages, the
/// shelves, the Discover gallery, the pushed post list and the flight card
/// that the place page, the profiles, post sets, hashtags, the sound sheet
/// and Search's trending draw posts with. They were Feed's; Feed, and
/// through it the rest, consume them here, so a profile's grid is built
/// without Feed's reader, comments or conversation.
let package = Package(
    name: "PostSurfaces",
    platforms: [.iOS("26.0")],
    products: [
        .library(name: "PostSurfaces", targets: ["PostSurfaces"])
    ],
    dependencies: [
        .package(path: "../../Kit/LaunchArguments"),
        .package(path: "../../Kit/CoreModels"),
        .package(path: "../PostGrid"),
        .package(path: "../DesignSystem"),
        .package(path: "../CoreNavigation"),
        .package(path: "../MediaCore"),
        .package(path: "../MediaPlayback"),
        .package(path: "../CoreStorage"),
        .package(path: "../EntityStore"),
        .package(path: "../EmoteKit"),
        .package(path: "../ThreadKit"),
        .package(path: "../VoiceKit")
    ],
    targets: [
        .target(
            name: "PostSurfaces",
            dependencies: [
                "LaunchArguments", "CoreModels", "PostGrid", "DesignSystem", "CoreNavigation",
                "MediaCore", "MediaPlayback", "CoreStorage", "EntityStore", "EmoteKit", "ThreadKit",
                .product(name: "VoiceKitUI", package: "VoiceKit")
            ]
        )
    ]
)
