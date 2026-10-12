// swift-tools-version: 6.0
import PackageDescription

// One post and one profile per id in memory (#896, epic #890): the identity
// map every screen reads, so a like, a follow, a save or a delete made anywhere
// reaches every screen showing it. Bounded and trimmed by the CacheKit
// coordinator; viewer-relative facts are their own namespace, wiped on every
// viewer change. Kept out of CoreStorage so only the packages that read
// entities link it.
let package = Package(
    name: "EntityStore",
    platforms: [.iOS("26.0")],
    products: [
        .library(name: "EntityStore", targets: ["EntityStore"])
    ],
    dependencies: [
        .package(path: "../CacheKit"),
        .package(path: "../../Kit/CoreModels")
    ],
    targets: [
        .target(name: "EntityStore", dependencies: ["CacheKit", "CoreModels"]),
        .testTarget(name: "EntityStoreTests", dependencies: ["EntityStore", "CacheKit", "CoreModels"])
    ]
)
