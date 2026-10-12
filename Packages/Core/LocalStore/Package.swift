// swift-tools-version: 6.0
import PackageDescription

// The device's structured data cache (#893, epic #890): copies of server data
// (posts, profiles, list pages and their cursors) in one SQLite file, so every
// tab opens on its last content at cold start. Viewer-scoped, budgeted by the
// CacheKit coordinator.
//
// SQLite through GRDB (decided 2026-10-11): a WAL `DatabasePool` (reads off the
// main thread in parallel with the one writer), cached prepared statements,
// `DatabaseMigrator`, and `ValueObservation` for the EntityStore (#896).
// Pinned to an EXACT version: a database library is not something a minor
// bump should change under a shipped schema. 7.11.1 (2026-06-18) needs
// Swift 6.1 / Xcode 16.3 and supports Xcode 26 since 7.7.0, so CI builds it.
let package = Package(
    name: "LocalStore",
    platforms: [.iOS("26.0")],
    products: [
        .library(name: "LocalStore", targets: ["LocalStore"])
    ],
    dependencies: [
        .package(path: "../CacheKit"),
        .package(url: "https://github.com/groue/GRDB.swift.git", exact: "7.11.1")
    ],
    targets: [
        .target(
            name: "LocalStore",
            dependencies: [
                "CacheKit",
                .product(name: "GRDB", package: "GRDB.swift")
            ]
        ),
        .testTarget(
            name: "LocalStoreTests",
            dependencies: [
                "LocalStore",
                "CacheKit",
                .product(name: "GRDB", package: "GRDB.swift")
            ]
        )
    ]
)
