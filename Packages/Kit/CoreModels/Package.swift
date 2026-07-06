// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CoreModels",
    platforms: [.iOS("26.5")],
    products: [
        .library(name: "CoreModels", targets: ["CoreModels"])
    ],
    targets: [
        .target(name: "CoreModels"),
        .testTarget(name: "CoreModelsTests", dependencies: ["CoreModels"])
    ]
)
