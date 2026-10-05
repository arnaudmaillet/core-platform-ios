// swift-tools-version: 6.0
import PackageDescription

/// The share sheet a profile and a place share: a QR card (the subject's
/// picture punched into its code), a row of people to send it to, and a tray
/// of actions — moved out of Profile on 5 October 2026 so the place page's QR
/// bubble opens the same sheet as the profile's.
let package = Package(
    name: "ShareSheet",
    platforms: [.iOS("26.0")],
    products: [
        .library(name: "ShareSheet", targets: ["ShareSheet"])
    ],
    dependencies: [
        .package(path: "../../Kit/CoreModels"),
        .package(path: "../CoreNavigation"),
        .package(path: "../DesignSystem"),
        .package(path: "../MediaCore")
    ],
    targets: [
        .target(
            name: "ShareSheet",
            dependencies: ["CoreModels", "CoreNavigation", "DesignSystem", "MediaCore"]
        ),
        .testTarget(name: "ShareSheetTests", dependencies: ["ShareSheet"])
    ]
)
