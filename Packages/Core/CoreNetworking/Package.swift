// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CoreNetworking",
    platforms: [.iOS("26.0")],
    products: [
        .library(name: "CoreNetworking", targets: ["CoreNetworking"]),
        // In-process fake BFF speaking the Connect protocol with binary proto,
        // for deterministic tests and mock-mode app runs.
        .library(name: "CoreNetworkingMocks", targets: ["CoreNetworkingMocks"])
    ],
    dependencies: [
        .package(path: "../../Kit/CoreContracts"),
        .package(path: "../MediaCore"),
        .package(url: "https://github.com/connectrpc/connect-swift.git", from: "1.0.0"),
        .package(url: "https://github.com/apple/swift-protobuf.git", from: "1.28.0")
    ],
    targets: [
        .target(
            name: "CoreNetworking",
            dependencies: [
                .product(name: "Connect", package: "connect-swift")
            ]
        ),
        .target(
            name: "CoreNetworkingMocks",
            dependencies: [
                "CoreNetworking",
                "CoreContracts",
                .product(name: "MediaCore", package: "MediaCore"),
                .product(name: "Connect", package: "connect-swift"),
                .product(name: "SwiftProtobuf", package: "swift-protobuf")
            ]
        ),
        .testTarget(
            name: "CoreNetworkingTests",
            dependencies: ["CoreNetworking", "CoreNetworkingMocks", "CoreContracts"]
        )
    ]
)
