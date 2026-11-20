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
        // The seam types the builder names (`GalleryPost`, `SnapFeedHeroOrigin`,
        // `TextRevealOrigin`): CoreModels, CoreNavigation and the design system
        // only. ⚠️ Never PostGrid or MediaCore (#2380,
        // `LayeringGuardTests.feedInterfaceStaysClearOfTheGrid`).
        .package(path: "../../Core/PostGridSeam"),
        .package(path: "../../Core/CoreNavigation"),
        // `OverSheetFeedHost` closes its sheet once (`closePresentation`, #1144).
        .package(path: "../../Core/DesignSystem")
    ],
    targets: [
        .target(
            name: "FeedInterface",
            dependencies: [
                "CoreModels", "PostGridSeam", "CoreNavigation", .product(name: "Transitions", package: "CoreNavigation"), "DesignSystem"]
        )
    ]
)
