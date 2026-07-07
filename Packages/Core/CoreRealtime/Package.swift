// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CoreRealtime",
    platforms: [.iOS("26.0")],
    products: [
        .library(name: "CoreRealtime", targets: ["CoreRealtime"]),
        // In-process fake of the realtime gateway for deterministic tests and
        // mock-mode app runs.
        .library(name: "CoreRealtimeMocks", targets: ["CoreRealtimeMocks"])
    ],
    dependencies: [
        .package(path: "../../Kit/CoreContracts")
    ],
    targets: [
        .target(
            name: "CoreRealtime",
            dependencies: ["CoreContracts"]
        ),
        .target(
            name: "CoreRealtimeMocks",
            dependencies: ["CoreRealtime", "CoreContracts"]
        ),
        .testTarget(
            name: "CoreRealtimeTests",
            dependencies: ["CoreRealtime", "CoreRealtimeMocks"]
        )
    ]
)
