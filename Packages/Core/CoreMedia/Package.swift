// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CoreMedia",
    platforms: [.iOS("26.0")],
    products: [
        .library(name: "CoreMedia", targets: ["CoreMedia"])
    ],
    targets: [
        .target(name: "CoreMedia"),
        .testTarget(name: "CoreMediaTests", dependencies: ["CoreMedia"])
    ]
)
