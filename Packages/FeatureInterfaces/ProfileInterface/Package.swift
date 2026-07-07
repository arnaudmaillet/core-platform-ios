// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ProfileInterface",
    platforms: [.iOS("26.5")],
    products: [
        .library(name: "ProfileInterface", targets: ["ProfileInterface"])
    ],
    targets: [
        .target(name: "ProfileInterface")
    ]
)
