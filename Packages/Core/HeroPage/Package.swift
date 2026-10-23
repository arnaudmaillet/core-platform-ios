// swift-tools-version: 6.0
import PackageDescription

/// The hero page (#1651): the screen a profile and a place page share — a
/// banner, an identity, counters and actions over paged content — as one
/// modular container each page kind composes, rather than two copies of the
/// same mechanics drifting apart.
let package = Package(
    name: "HeroPage",
    platforms: [.iOS("26.0")],
    products: [
        .library(name: "HeroPage", targets: ["HeroPage"])
    ],
    dependencies: [
        // `HeaderIdentityFade`, the hero kit's primitives.
        .package(path: "../DesignSystem")
    ],
    targets: [
        .target(name: "HeroPage", dependencies: ["DesignSystem"]),
        .testTarget(name: "HeroPageTests", dependencies: ["HeroPage"])
    ]
)
