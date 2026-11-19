// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "FeedInterface",
    platforms: [.iOS("26.0")],
    products: [
        .library(name: "FeedInterface", targets: ["FeedInterface"])
    ],
    dependencies: [
        .package(path: "../../Kit/CoreModels"),
        // The grid page's and the hero flight's seam types the builder names
        // (`PostGridPage`, `SnapFeedHeroOrigin`, `TextRevealOrigin`,
        // `GalleryPost`): the last edge to a Core package beyond navigation
        // and the design system (#2380, stage 3).
        .package(path: "../../Core/PostGrid"),
        .package(path: "../../Core/CoreNavigation"),
        // `OverSheetFeedHost` closes its sheet once (`closePresentation`, #1144).
        .package(path: "../../Core/DesignSystem")
    ],
    targets: [
        .target(
            name: "FeedInterface",
            dependencies: [
                "CoreModels", "PostGrid", "CoreNavigation", .product(name: "Transitions", package: "CoreNavigation"), "DesignSystem"]
        )
    ]
)
