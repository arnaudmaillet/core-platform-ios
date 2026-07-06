// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "UploadInterface",
    platforms: [.iOS("26.5")],
    products: [
        .library(name: "UploadInterface", targets: ["UploadInterface"])
    ],
    targets: [
        .target(name: "UploadInterface")
    ]
)
