// swift-tools-version: 6.0
import PackageDescription

// The repository's guards (#2371, epic #2366): tests that read the app's and
// the packages' sources and manifests, and fail on a shape a contract retires.
// They used to live in the test targets of the packages whose contract they
// keep (DesignSystem, MediaCore, CoreNavigation, HeroPage, Feed), so a pull
// request that never touched those packages skipped them, went green, and
// reddened develop. This package depends on nothing and builds in seconds;
// `select_packages.py` picks its lane for every pull request.
let package = Package(
    name: "RepoGuards",
    platforms: [.iOS("26.0")],
    products: [
        .library(name: "RepoGuards", targets: ["RepoGuards"])
    ],
    targets: [
        .target(name: "RepoGuards"),
        .testTarget(name: "RepoGuardsTests", dependencies: ["RepoGuards"])
    ]
)
