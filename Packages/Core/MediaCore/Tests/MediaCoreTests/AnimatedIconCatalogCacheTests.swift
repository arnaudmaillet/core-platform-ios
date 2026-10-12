import CacheKit
import Foundation
import Testing
import UIKit
@testable import MediaCore

/// Resident animated icons live in the device cache's UI assets class (#971):
/// kept through a memory warning and the background, dropped on a critical
/// warning, and counted by the cache's own accounting.
@MainActor
final class AnimatedIconCatalogCacheTests {
    private let folder = FileManager.default.temporaryDirectory
        .appendingPathComponent("icon-catalog-\(UUID().uuidString)", isDirectory: true)

    deinit {
        try? FileManager.default.removeItem(at: folder)
    }

    /// A bundle holding a two-icon manifest: one sheet, one decomposed still.
    private func makeBundle() throws -> Bundle {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 32, height: 16))
        let png = try #require(renderer.image { context in
            UIColor.systemTeal.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 32, height: 16))
        }.pngData())
        try png.write(to: folder.appendingPathComponent("sheet.png"))
        try png.write(to: folder.appendingPathComponent("still.png"))
        let manifest = """
        [
          {"id": "wave", "kind": "sheet", "asset": "sheet.png", "frameCount": 2, "frameMS": 33, "cellPX": 16, "columns": 2},
          {"id": "spin", "kind": "still", "asset": "still.png", "frameCount": 2, "frameMS": 33, "cellPX": 16,
           "scale": [1, 1, 1], "rotation": [0, 1, 2], "opacity": [1, 1, 1]}
        ]
        """
        try Data(manifest.utf8).write(to: folder.appendingPathComponent("icons.json"))
        try Data(manifest.utf8).write(to: folder.appendingPathComponent("previews.json"))
        return try #require(Bundle(url: folder))
    }

    @Test func residentIconsAreUIAssetsKeptUntilACriticalWarning() async throws {
        let coordinator = CacheCoordinator(
            device: CacheDevice(physicalMemory: { 6 << 30 }, availableDiskCapacity: { 100_000_000_000 })
        )
        let registry = UIAssetCaches()
        registry.attach(to: coordinator)
        let catalog = AnimatedIconCatalog(bundle: try makeBundle(), manifest: "icons", registry: registry)
        #expect(catalog.cache.namespace == UIAssetCaches.namespace("UIAssets.icons.icons"))
        #expect(coordinator.registeredCaches.contains { $0 === catalog.cache })
        #expect(catalog.cache.limits.bytes == 24 << 20, "the catalogue's own byte budget")

        _ = try await catalog.art(for: "wave")
        _ = try await catalog.art(for: "spin")
        #expect(catalog.residentCount == 2)
        #expect(catalog.residentDecomposed == 1)
        #expect(catalog.residentBytes == catalog.cache.usage.bytes)
        #expect(catalog.residentBytes > 0)

        coordinator.trim(.memoryWarning)
        coordinator.trim(.background)
        #expect(catalog.cached("wave") != nil, "a warning and the background keep icons")
        #expect(catalog.residentCount == 2)

        coordinator.trim(.memoryCritical)
        #expect(catalog.cached("wave") == nil)
        #expect(catalog.residentCount == 0, "the resident figure follows the cache down")
        #expect(catalog.residentDecomposed == 0)
        #expect(catalog.residentBytes == 0)

        // …and comes back on the next ask.
        _ = try await catalog.art(for: "wave")
        #expect(catalog.residentCount == 1)
    }

    /// The map's preview sheets are feed media in all but format: a catalogue
    /// of the `standard` class goes with the feed when the app backgrounds,
    /// where an icon catalogue stays.
    @Test func aStandardCatalogueGoesWithTheFeed() async throws {
        let coordinator = CacheCoordinator(
            device: CacheDevice(physicalMemory: { 6 << 30 }, availableDiskCapacity: { 100_000_000_000 })
        )
        let registry = UIAssetCaches()
        registry.attach(to: coordinator)
        let bundle = try makeBundle()
        let previews = AnimatedIconCatalog(bundle: bundle, manifest: "previews", priorityClass: .standard, registry: registry)
        let icons = AnimatedIconCatalog(bundle: bundle, manifest: "icons", registry: registry)
        #expect(previews.cache.namespace.priorityClass == .standard)
        #expect(icons.cache.namespace.priorityClass == .persistent)
        _ = try await previews.art(for: "wave")
        _ = try await icons.art(for: "wave")

        coordinator.trim(.background)
        #expect(previews.cached("wave") == nil, "previews went with the feed")
        #expect(icons.cached("wave") != nil, "icons stayed")
    }

    /// A logout keeps icons: they are public art, the same for any viewer.
    @Test func aLogoutKeepsIcons() async throws {
        let coordinator = CacheCoordinator(
            device: CacheDevice(physicalMemory: { 6 << 30 }, availableDiskCapacity: { 100_000_000_000 })
        )
        let registry = UIAssetCaches()
        registry.attach(to: coordinator)
        let catalog = AnimatedIconCatalog(bundle: try makeBundle(), manifest: "icons", registry: registry)
        _ = try await catalog.art(for: "wave")
        coordinator.handle(.viewerChanged)
        #expect(catalog.cached("wave") != nil)
    }
}
