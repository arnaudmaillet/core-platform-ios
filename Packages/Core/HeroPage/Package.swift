// swift-tools-version: 6.0
import PackageDescription

/// The hero page (#1651): the screen a profile and a place page share — a
/// banner, an identity, counters and actions over paged content — as one
/// modular container each page kind composes, rather than two copies of the
/// same mechanics drifting apart.
let package = Package(
    name: "HeroPage",
    platforms: [.iOS("26.0")],
    products: [
        .library(name: "HeroPage", targets: ["HeroPage"])
    ],
    dependencies: [
        .package(path: "../../Kit/LaunchArguments"),
        // `HeaderIdentityFade`, the hero kit's primitives.
        .package(path: "../DesignSystem"),
        // The pages the pager hosts (`PostGridPage`, #1653).
        .package(path: "../../FeatureInterfaces/FeedInterface"),
        // `MediaCarouselTouchRouting`: a carousel with somewhere to go keeps
        // its drag from the pager.
        .package(path: "../PostGrid"),
        // The header's pictures: the avatar and the banner's (`ImagePipeline`,
        // `AvatarView`), the banner's loop, a bio's emotes.
        .package(path: "../MediaCore"),
        .package(path: "../MediaPlayback"),
        .package(path: "../EmoteKit"),
        // The lists behind the counters (#2237): the full-surface back
        // swipe's gate (`ContentPopGating`), as the profile's lists wear it.
        .package(path: "../CoreNavigation")
    ],
    targets: [
        .target(name: "HeroPage", dependencies: [
            "LaunchArguments",
            "DesignSystem", "FeedInterface", "PostGrid", "MediaCore", "MediaPlayback", "EmoteKit", "CoreNavigation"
        ]),
        .testTarget(name: "HeroPageTests", dependencies: ["HeroPage", "DesignSystem", "FeedInterface", "PostGrid", "MediaCore"])
    ]
)
