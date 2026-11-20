// swift-tools-version: 6.0
import PackageDescription

/// The grid's seam types (#2380, epic #2366): the post a grid draws
/// (`GalleryPost`), the hero flight's and the text reveal's origins
/// (`SnapFeedHeroOrigin`, `TextRevealOrigin`), the page a reader closes down
/// onto (`FeedBeneathLanding`) and the author band's model. They were
/// PostGrid's; FeedInterface's builder names them, and through PostGrid it
/// reached MediaCore and the cells. PostGrid re-exports this package, so
/// `import PostGrid` still sees every one of them.
///
/// ⚠️ KEEP IT LIGHT: CoreModels, CoreNavigation and the design system only.
/// No MediaCore, no PostGrid: FeedInterface depends on this package
/// (`LayeringGuardTests.feedInterfaceStaysClearOfTheGrid`).
let package = Package(
    name: "PostGridSeam",
    platforms: [.iOS("26.0")],
    products: [
        .library(name: "PostGridSeam", targets: ["PostGridSeam"])
    ],
    dependencies: [
        .package(path: "../../Kit/CoreModels"),
        .package(path: "../CoreNavigation"),
        // The reveal's card fill (`Surface.card`), the band's monogram and its
        // relation mark. CoreNavigation depends on it already.
        .package(path: "../DesignSystem")
    ],
    targets: [
        .target(
            name: "PostGridSeam",
            dependencies: [
                "CoreModels", "CoreNavigation", .product(name: "Transitions", package: "CoreNavigation"), "DesignSystem"
            ]
        )
    ]
)
