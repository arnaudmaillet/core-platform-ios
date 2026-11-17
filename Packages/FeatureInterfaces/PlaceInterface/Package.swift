// swift-tools-version: 6.0
import PackageDescription

// The Place feature's contract (#2381): the place page's builder, and the
// values the map hands it (its rank, identity, query and dock pin). Maps and
// the app shell depend on this, never on Place itself.
let package = Package(
    name: "PlaceInterface",
    platforms: [.iOS("26.0")],
    products: [
        .library(name: "PlaceInterface", targets: ["PlaceInterface"])
    ],
    dependencies: [
        .package(path: "../../Kit/CoreModels"),
        // `ZoomTransitionSource` and `RevealGeometry`, the map's way home.
        .package(path: "../../Core/CoreNavigation")
    ],
    targets: [
        .target(name: "PlaceInterface", dependencies: ["CoreModels", "CoreNavigation"])
    ]
)
