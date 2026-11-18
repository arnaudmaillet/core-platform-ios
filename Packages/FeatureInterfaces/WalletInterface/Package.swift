// swift-tools-version: 6.0
import PackageDescription

// What the economy's features sell to each other (#2385): the stake packs and
// the profile items. Maps' Shop shows them, the Wallet feature answers them;
// neither names the other.
let package = Package(
    name: "WalletInterface",
    platforms: [.iOS("26.0")],
    products: [
        .library(name: "WalletInterface", targets: ["WalletInterface"])
    ],
    dependencies: [
        // `ProfileItem` and `ProfileItemPurchase`.
        .package(path: "../../Core/CoreStorage")
    ],
    targets: [
        .target(name: "WalletInterface", dependencies: ["CoreStorage"])
    ]
)
