// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ProfileInterface",
    platforms: [.iOS("26.0")],
    products: [
        .library(name: "ProfileInterface", targets: ["ProfileInterface"])
    ],
    dependencies: [
        .package(path: "../../Kit/CoreModels"),
        // `ProfileItem`, for `ProfileItemAccess` (#2385).
        .package(path: "../../Core/CoreStorage")
    ],
    targets: [
        .target(
            name: "ProfileInterface",
            dependencies: ["CoreModels", "CoreStorage"]
        )
    ]
)
