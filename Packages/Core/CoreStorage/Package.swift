// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CoreStorage",
    platforms: [.iOS("26.0")],
    products: [
        .library(name: "CoreStorage", targets: ["CoreStorage"])
    ],
    dependencies: [
        .package(path: "../../Kit/CoreModels")
    ],
    targets: [
        .target(name: "CoreStorage", dependencies: ["CoreModels"]),
        .testTarget(name: "CoreStorageTests", dependencies: ["CoreStorage"])
    ]
)
