// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AuthInterface",
    platforms: [.iOS("26.5")],
    products: [
        .library(name: "AuthInterface", targets: ["AuthInterface"])
    ],
    dependencies: [
        .package(path: "../../Kit/CoreModels")
    ],
    targets: [
        .target(name: "AuthInterface", dependencies: ["CoreModels"])
    ]
)
