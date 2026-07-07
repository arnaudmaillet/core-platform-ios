// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ProfileInterface",
    platforms: [.iOS("26.5")],
    products: [
        .library(name: "ProfileInterface", targets: ["ProfileInterface"])
    ],
    dependencies: [
        .package(path: "../../Kit/CoreModels")
    ],
    targets: [
        .target(
            name: "ProfileInterface",
            dependencies: ["CoreModels"]
        )
    ]
)
