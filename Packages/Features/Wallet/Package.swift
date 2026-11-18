// swift-tools-version: 6.2
import PackageDescription

// The wallet (#2385, epic #2366): its sheet and its cards, the claim, the
// history, the stakes and how it works; the server sync, the refund notices,
// the server wallet (wallet.v1), and the sellers of stake packs and profile
// items. It lived in App, which has no unit-test target, and in Feed.
//
// The Shop stays with Maps (it is built on the country atlas); the sheet
// opens it through `makeShop`, which the app fills. Maps and the wallet meet
// only through WalletInterface.
//
// ⚠️ THE APP'S ISOLATION, KEPT. These files were written under App's
// `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` and approachable concurrency;
// the target says the same (tools 6.2), so their meaning did not change with
// the move.
let package = Package(
    name: "Wallet",
    platforms: [.iOS("26.0")],
    products: [
        .library(name: "Wallet", targets: ["Wallet"])
    ],
    dependencies: [
        .package(path: "../../Kit/LaunchArguments"),
        .package(path: "../../Kit/CoreContracts"),
        .package(path: "../../Kit/CoreModels"),
        .package(path: "../../FeatureInterfaces/AuthInterface"),
        .package(path: "../../FeatureInterfaces/FeedInterface"),
        .package(path: "../../FeatureInterfaces/ProfileInterface"),
        .package(path: "../../FeatureInterfaces/WalletInterface"),
        .package(path: "../../Core/CacheKit"),
        .package(path: "../../Core/CoreNavigation"),
        .package(path: "../../Core/CoreNetworking"),
        .package(path: "../../Core/CoreStorage"),
        .package(path: "../../Core/DesignSystem"),
        .package(path: "../../Core/LocalStore"),
        .package(path: "../../Core/MediaCore"),
        .package(path: "../../Core/PostGrid"),
        .package(url: "https://github.com/apple/swift-protobuf.git", from: "1.28.0")
    ],
    targets: [
        .target(
            name: "Wallet",
            dependencies: [
                "LaunchArguments", "CoreContracts", "CoreModels", "AuthInterface", "FeedInterface",
                "ProfileInterface", "WalletInterface", "CacheKit", "CoreNavigation",
                .product(name: "Transitions", package: "CoreNavigation"), "CoreNetworking", "CoreStorage",
                "DesignSystem", "LocalStore", "MediaCore", .product(name: "MediaUI", package: "MediaCore"),
                "PostGrid", .product(name: "SwiftProtobuf", package: "swift-protobuf")
            ],
            swiftSettings: [
                .defaultIsolation(MainActor.self),
                .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
                .enableUpcomingFeature("InferIsolatedConformances")
            ]
        ),
        .testTarget(
            name: "WalletTests",
            dependencies: [
                "Wallet", "WalletInterface", "AuthInterface", "CoreContracts", "CoreModels", "CoreNetworking",
                .product(name: "CoreNetworkingMocks", package: "CoreNetworking"), "CoreStorage",
                .product(name: "SwiftProtobuf", package: "swift-protobuf")
            ]
        )
    ]
)
