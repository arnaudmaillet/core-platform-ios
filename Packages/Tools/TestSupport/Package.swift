// swift-tools-version: 6.0
import PackageDescription

// What every test target needs and each used to write for itself (#2389,
// epic #2366): the wait for a condition (218 copies of `settle` in 185 files,
// about ten signatures), and later the window fixture and the traits that
// reset global state. A tool: it depends on nothing, and any test target may
// depend on it.
let package = Package(
    name: "TestSupport",
    platforms: [.iOS("26.0")],
    products: [
        .library(name: "TestSupport", targets: ["TestSupport"])
    ],
    targets: [
        .target(name: "TestSupport"),
        .testTarget(name: "TestSupportTests", dependencies: ["TestSupport"])
    ]
)
