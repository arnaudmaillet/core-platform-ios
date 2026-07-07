// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "NotificationsInterface",
    platforms: [.iOS("26.0")],
    products: [
        .library(name: "NotificationsInterface", targets: ["NotificationsInterface"])
    ],
    targets: [
        .target(name: "NotificationsInterface")
    ]
)
