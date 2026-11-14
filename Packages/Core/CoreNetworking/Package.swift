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
        .package(path: "../../Kit/LaunchArguments"),
        .package(path: "../../Kit/CoreContracts"),
        .package(path: "../../Kit/CoreModels"),
        .package(url: "https://github.com/connectrpc/connect-swift.git", from: "1.0.0"),
        .package(url: "https://github.com/apple/swift-protobuf.git", from: "1.28.0")
    ],
    targets: [
        .target(
            name: "CoreNetworking",
            dependencies: [
                // ⚠️ `PostCounterReader` speaks counter.v1, so this target now
                // needs the generated contracts. The package already depended on
                // them for `CoreNetworkingMocks`, which is why the app built
                // locally and only a clean CI build said otherwise: a resolved
                // module is visible to the whole graph long after the target
                // that declared it stopped being the only one using it.
                "CoreContracts",
                // `AuthorSummary(profileView:)` (#1858): a profile view as the
                // person every screen shows.
                .product(name: "CoreModels", package: "CoreModels"),
                .product(name: "Connect", package: "connect-swift"),
                // `PostVoiceWire` (#2206) reads and writes a message's
                // unknown fields; `ProposedChat` (#2213) carries its JSON in
                // a well-known `StringValue`.
                .product(name: "SwiftProtobuf", package: "swift-protobuf")
            ]
        ),
        .target(
            name: "CoreNetworkingMocks",
            dependencies: [
                "LaunchArguments",
                "CoreNetworking",
                "CoreContracts",
                // `PostVoice`, the seeded voice posts (#2206).
                .product(name: "CoreModels", package: "CoreModels"),
                .product(name: "Connect", package: "connect-swift"),
                .product(name: "SwiftProtobuf", package: "swift-protobuf")
            ],
            // The real clips and sounds the mock corpus plays (see
            // `MockClipCatalog`) and the photo galleries it shows
            // (`MockPhotoCatalog`). Folder references, so the manifests keep
            // their file names.
            resources: [
                .copy("Resources/MockClips"),
                .copy("Resources/MockSongs"),
                .copy("Resources/MockPhotos"),
                // The seeded voice messages (#2103, `MockVoiceCatalog`).
                .copy("Resources/MockVoices")
            ]
        ),
        .testTarget(
            name: "CoreNetworkingTests",
            dependencies: [
                "CoreNetworking", "CoreNetworkingMocks", "CoreContracts",
                // A like batch's `first_tap_at` (#676).
                .product(name: "SwiftProtobuf", package: "swift-protobuf")
            ]
        )
    ]
)
