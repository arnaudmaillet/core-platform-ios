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
        .package(path: "../../Core/CoreNavigation")
    ],
    targets: [
        .target(
            name: "FeedInterface",
            dependencies: ["CoreModels", "PostGrid", "CoreNavigation"]
        )
    ]
)
