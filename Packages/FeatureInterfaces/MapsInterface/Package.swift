// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MapsInterface",
    platforms: [.iOS("26.0")],
    products: [
        .library(name: "MapsInterface", targets: ["MapsInterface"])
    ],
    targets: [
        .target(name: "MapsInterface")
    ]
)
