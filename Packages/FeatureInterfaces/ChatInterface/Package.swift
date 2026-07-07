// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ChatInterface",
    platforms: [.iOS("26.0")],
    products: [
        .library(name: "ChatInterface", targets: ["ChatInterface"])
    ],
    dependencies: [
        .package(path: "../../Kit/CoreModels")
    ],
    targets: [
        .target(
            name: "ChatInterface",
            dependencies: ["CoreModels"]
        )
    ]
)
