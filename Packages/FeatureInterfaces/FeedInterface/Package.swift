// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "FeedInterface",
    platforms: [.iOS("26.5")],
    products: [
        .library(name: "FeedInterface", targets: ["FeedInterface"])
    ],
    targets: [
        .target(name: "FeedInterface")
    ]
)
