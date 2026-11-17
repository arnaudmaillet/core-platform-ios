// swift-tools-version: 6.0
import PackageDescription

// The app's own state stored on this iPhone, out of DesignSystem (#2383):
// - App Lock (#418): the switch and its delay, the device authenticator,
//   and the lock screen;
// - the appearance, light, dark or following iOS (#468), applied to every
//   window.
// Editing them no longer rebuilds DesignSystem's dependents. The motion,
// Low Power Mode and emoji switches stay in DesignSystem, because its
// components read them.
let package = Package(
    name: "AppPreferences",
    platforms: [.iOS("26.0")],
    products: [
        .library(name: "AppPreferences", targets: ["AppPreferences"])
    ],
    dependencies: [
        // The lock screen's type.
        .package(path: "../DesignSystem")
    ],
    targets: [
        .target(name: "AppPreferences", dependencies: ["DesignSystem"]),
        .testTarget(name: "AppPreferencesTests", dependencies: ["AppPreferences"])
    ]
)
