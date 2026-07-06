// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CoreNavigation",
    platforms: [.iOS("26.5")],
    products: [
        .library(name: "CoreNavigation", targets: ["CoreNavigation"])
    ],
    dependencies: [
        .package(path: "../../Kit/CoreModels")
    ],
    targets: [
        .target(name: "CoreNavigation", dependencies: ["CoreModels"]),
        .testTarget(name: "CoreNavigationTests", dependencies: ["CoreNavigation"])
    ]
)
