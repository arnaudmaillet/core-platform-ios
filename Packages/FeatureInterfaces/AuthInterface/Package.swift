// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AuthInterface",
    platforms: [.iOS("26.0")],
    products: [
        .library(name: "AuthInterface", targets: ["AuthInterface"])
    ],
    dependencies: [
        .package(path: "../../Kit/CoreModels"),
        // `AppCacheSignals`: a viewer transition is a release signal of the one
        // device cache (#890), mapped next to the notification that announces it.
        .package(path: "../../Core/CacheKit")
    ],
    targets: [
        .target(name: "AuthInterface", dependencies: ["CoreModels", "CacheKit"]),
        .testTarget(name: "AuthInterfaceTests", dependencies: ["AuthInterface", "CoreModels", "CacheKit"])
    ]
)
