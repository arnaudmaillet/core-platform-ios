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
        .package(path: "../../Core/PostGrid"),
        // `PersonBarItem` speaks `PersonPill.Badge` and `ImagePipeline` (#1451).
        .package(path: "../../Core/MediaCore"),
        .package(path: "../../Core/CoreNavigation")
    ],
    targets: [
        .target(
            name: "FeedInterface",
            dependencies: ["CoreModels", "PostGrid", "CoreNavigation", "MediaCore"]
        )
    ]
)
