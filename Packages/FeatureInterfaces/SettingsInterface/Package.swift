// swift-tools-version: 6.0
import PackageDescription

// What the app and the profile need to open Settings (#2382, stage 3): the
// feature's builder, the section a QA launch argument opens, and the web
// pages Settings links to, which the sign-in sheet's legal line names too.
// The Settings feature answers it; the app wires it.
let package = Package(
    name: "SettingsInterface",
    platforms: [.iOS("26.0")],
    products: [
        .library(name: "SettingsInterface", targets: ["SettingsInterface"])
    ],
    targets: [
        .target(name: "SettingsInterface")
    ]
)
