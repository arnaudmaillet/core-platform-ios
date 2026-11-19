// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "NotificationsInterface",
    platforms: [.iOS("26.0")],
    products: [
        .library(name: "NotificationsInterface", targets: ["NotificationsInterface"])
    ],
    dependencies: [
        // `PushPayload`'s destinations name a post or a profile (#2375).
        .package(path: "../../Kit/CoreModels")
    ],
    targets: [
        .target(name: "NotificationsInterface", dependencies: ["CoreModels"])
    ]
)
