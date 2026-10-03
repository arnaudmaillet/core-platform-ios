// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CoreNavigation",
    platforms: [.iOS("26.0")],
    products: [
        .library(name: "CoreNavigation", targets: ["CoreNavigation"])
    ],
    dependencies: [
        .package(path: "../../Kit/CoreModels"),
        // `MotionPreference`: the hero motion policy and the drawer honour the
        // app-level Reduce Motion alongside the iOS setting (#468).
        .package(path: "../DesignSystem")
    ],
    targets: [
        .target(name: "CoreNavigation", dependencies: ["CoreModels", "DesignSystem"]),
        .testTarget(name: "CoreNavigationTests", dependencies: ["CoreNavigation"])
    ]
)
