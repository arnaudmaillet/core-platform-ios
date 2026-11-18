// swift-tools-version: 6.0
import PackageDescription

// Four targets, one per responsibility (#2384), each built on the ones above
// it in this list:
//
//   Instrumentation   interaction latency, the zoom census, settle watches
//   CoreNavigation    routes, tabs, the drawer, the arbiters, the viewport
//                     share and the screen covers
//   Transitions       the hero, zoom, reveal and slide transition engine
//   DebugDashboard    the DEBUG dashboard and its interface tools
//
// One package, so they share `package` access.
let package = Package(
    name: "CoreNavigation",
    platforms: [.iOS("26.0")],
    products: [
        .library(name: "CoreNavigation", targets: ["CoreNavigation"]),
        .library(name: "Transitions", targets: ["Transitions"]),
        .library(name: "Instrumentation", targets: ["Instrumentation"]),
        .library(name: "DebugDashboard", targets: ["DebugDashboard"])
    ],
    dependencies: [
        .package(path: "../../Kit/LaunchArguments"),
        .package(path: "../../Kit/CoreModels"),
        // `MotionPreference`: the hero motion policy and the drawer honour the
        // app-level Reduce Motion alongside the iOS setting (#468).
        .package(path: "../DesignSystem")
    ],
    targets: [
        .target(name: "Instrumentation", dependencies: ["LaunchArguments", "CoreModels", "DesignSystem"]),
        .target(
            name: "CoreNavigation",
            dependencies: ["Instrumentation", "LaunchArguments", "CoreModels", "DesignSystem"]
        ),
        .target(
            name: "Transitions",
            dependencies: ["CoreNavigation", "Instrumentation", "LaunchArguments", "CoreModels", "DesignSystem"]
        ),
        .target(
            name: "DebugDashboard",
            dependencies: ["CoreNavigation", "Transitions", "Instrumentation", "LaunchArguments", "CoreModels", "DesignSystem"]
        ),
        .testTarget(
            name: "CoreNavigationTests",
            dependencies: ["CoreNavigation", "Transitions", "Instrumentation", "DebugDashboard"]
        )
    ]
)
