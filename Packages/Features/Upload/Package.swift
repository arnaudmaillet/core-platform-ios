// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Upload",
    platforms: [.iOS("26.0")],
    products: [
        .library(name: "Upload", targets: ["Upload"])
    ],
    dependencies: [
        .package(path: "../../FeatureInterfaces/AuthInterface"),
        // The Text Post screen is drawn by Feed. The INTERFACE only — Upload
        // hands it a publisher, the way Chat hands it a thread driver.
        .package(path: "../../FeatureInterfaces/FeedInterface"),
        .package(path: "../../Kit/CoreContracts"),
        .package(path: "../../Kit/CoreModels"),
        // The picker wears the app's chrome: the segmented strip in its bottom
        // toolbar, the spacing scale, the empty states.
        .package(path: "../../Core/DesignSystem"),
        .package(path: "../../Core/MediaCore"),
        .package(path: "../../Core/MediaPlayback"),
        .package(path: "../../Core/CoreNetworking")
    ],
    targets: [
        .target(
            name: "Upload",
            dependencies: [
                "AuthInterface",
                "FeedInterface",
                "CoreContracts",
                "CoreModels",
                "DesignSystem",
                "MediaCore",
                "MediaPlayback"
            ]
        ),
        .testTarget(
            name: "UploadTests",
            dependencies: [
                "Upload",
                "FeedInterface",
                // Declared because the tests import it: the editor's tests read
                // what its category strip is wearing, and `PagedTabBar` is
                // DesignSystem's. It would compile without this line — SwiftPM
                // puts every package dependency's module on the search path for
                // each target here, which is why the composer's tests import
                // five modules this list never names — so this states intent
                // rather than fixing a break.
                "DesignSystem",
                // Same reason: `NewPostTests` synthesises a real clip with
                // `PlaceholderVideoFetcher` so the publish path opens genuine
                // H.264 bytes rather than a URL that merely looks like one.
                "MediaPlayback",
                "CoreNetworking",
                .product(name: "CoreNetworkingMocks", package: "CoreNetworking")
            ]
        )
    ]
)
