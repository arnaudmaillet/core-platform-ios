// swift-tools-version: 6.0
import PackageDescription

// Generated protobuf contracts for buf.build/core-platform/contracts.
// Sources/CoreContracts/Generated is machine-written by Scripts/generate-contracts.sh
// (pin in .contracts-pin) — never edit it by hand.
//
// These types are wire DTOs: import them in repositories / Data layers only,
// and map to domain or display models at the repository boundary.
let package = Package(
    name: "CoreContracts",
    platforms: [.iOS("26.5")],
    products: [
        .library(name: "CoreContracts", targets: ["CoreContracts"])
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-protobuf.git", from: "1.28.0"),
        .package(url: "https://github.com/connectrpc/connect-swift.git", from: "1.0.0")
    ],
    targets: [
        .target(
            name: "CoreContracts",
            dependencies: [
                .product(name: "SwiftProtobuf", package: "swift-protobuf"),
                .product(name: "Connect", package: "connect-swift")
            ]
        )
    ]
)
