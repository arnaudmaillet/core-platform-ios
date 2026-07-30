// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PostGrid",
    platforms: [.iOS("26.0")],
    products: [
        .library(name: "PostGrid", targets: ["PostGrid"])
    ],
    dependencies: [
        .package(path: "../../Kit/CoreModels"),
        .package(path: "../MediaCore"),
        .package(path: "../MediaPlayback"),
        .package(path: "../DesignSystem")
    ],
    targets: [
        .target(
            name: "PostGrid",
            dependencies: ["CoreModels", "MediaCore", "MediaPlayback", "DesignSystem"]
        ),
        .testTarget(name: "PostGridTests", dependencies: ["PostGrid"])
    ]
)
