// swift-tools-version: 6.0
import PackageDescription

// The device cache's shared pieces (#891, epic #890): a byte-budgeted memory
// cache, a disk store with an LRU index, priority tiers, leases, coalesced
// fills, and the one coordinator that owns every budget. No dependency on
// purpose: the image pipeline, the video cache and the LocalStore all plug
// into it, so it cannot depend on any of them.
let package = Package(
    name: "CacheKit",
    platforms: [.iOS("26.0")],
    products: [
        .library(name: "CacheKit", targets: ["CacheKit"])
    ],
    targets: [
        .target(name: "CacheKit"),
        .testTarget(name: "CacheKitTests", dependencies: ["CacheKit"])
    ]
)
