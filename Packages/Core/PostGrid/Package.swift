// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PostGrid",
    platforms: [.iOS("26.0")],
    products: [
        .library(name: "PostGrid", targets: ["PostGrid"])
    ],
    dependencies: [
        .package(path: "../../Kit/CoreModels"),
        .package(path: "../MediaCore"),
        .package(path: "../MediaPlayback"),
        .package(path: "../DesignSystem"),
        // For `RevealStandInShaping` only — the stand-in card a reveal's
        // dismissal flies is a CARD, so it lives beside the cell it copies, and
        // the transition vocabulary it satisfies lives in CoreNavigation.
        // CoreNavigation depends on CoreModels alone, so this adds an edge and
        // no cycle.
        .package(path: "../CoreNavigation")
    ],
    targets: [
        .target(
            name: "PostGrid",
            dependencies: [
                "CoreModels", "MediaCore", "MediaPlayback", "DesignSystem", "CoreNavigation"
            ]
        ),
        .testTarget(name: "PostGridTests", dependencies: ["PostGrid"])
    ]
)
