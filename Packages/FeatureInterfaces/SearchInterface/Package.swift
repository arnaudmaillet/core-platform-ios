// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SearchInterface",
    platforms: [.iOS("26.0")],
    products: [
        .library(name: "SearchInterface", targets: ["SearchInterface"])
    ],
    targets: [
        .target(name: "SearchInterface")
    ]
)
