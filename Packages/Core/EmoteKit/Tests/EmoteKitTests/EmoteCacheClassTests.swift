import CacheKit
import Foundation
import MediaCore
import Testing
import UIKit
@testable import EmoteKit

/// Emotes in the device cache's UI assets class (#971): the engine's real
/// caches registered with a coordinator next to feed namespaces. Every test
/// builds its own coordinator, registry and folder; none touches the shared
/// ones.
@MainActor
@Suite(.serialized, .sharesMainThread)
final class EmoteCacheClassTests {
    private let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("emote-class-\(UUID().uuidString)", isDirectory: true)

    deinit {
        try? FileManager.default.removeItem(at: root)
    }

    private func makeCoordinator(limit: CacheStorageLimit = .automatic) -> CacheCoordinator {
        CacheCoordinator(
            device: CacheDevice(physicalMemory: { 6 << 30 }, availableDiskCapacity: { 100_000_000_000 }),
            storageLimit: limit
        )
    }

    /// An engine whose memory and disk are announced to `registry`, the way
    /// the shared engine's are to `UIAssetCaches.shared`.
    private func makeEngine(registry: UIAssetCaches, disk: DiskStore? = nil) -> EmoteEngine {
        let memory: MemoryCache<String, AnimatedIconArt> = UIAssetCaches.memoryCache("UIAssets.emotes", budget: EmoteEngine.memoryBudget)
        if let disk { registry.adopt(disk) }
        return EmoteEngine(
            diskCache: disk.map { store in EmoteDiskCache { store } }, memory: memory, registry: registry,
            animationProvider: { _ in nil }
        )
    }

    private func emotes(_ count: Int) -> [Emote] {
        Array(EmoteCatalog.shared.all.filter(\.isUnicodeEmoji).prefix(count))
    }

    private func feed(_ name: String, scope: CacheScope = .public) -> MemoryCache<String, Data> {
        MemoryCache(
            namespace: CacheNamespace(name, category: .images, scope: scope, priorityClass: .standard),
            budget: .decodedImages
        )
    }

    @Test func theEngineCachesAreInTheUIAssetsClass() {
        let engine = EmoteEngine(diskCache: nil)
        #expect(engine.memory.namespace.priorityClass == .persistent)
        #expect(engine.memory.namespace.scope == .public)
        #expect(engine.memory.memoryBudget == EmoteEngine.memoryBudget)
        // 1% of RAM, 32–64 MB: a 6 GB device holds a whole keyboard screen
        // (about 50 MB, #926), an 8 GB one is capped, a 3 GB one keeps 32.
        #expect(EmoteEngine.memoryBudget.bytes(physicalMemory: 6 << 30) > 60 << 20)
        #expect(EmoteEngine.memoryBudget.bytes(physicalMemory: 8 << 30) == 64 << 20)
        #expect(EmoteEngine.memoryBudget.bytes(physicalMemory: 3 << 30) == 32 << 20)
    }

    /// THE TRIM ORDER: every speculative and recent feed entry goes before a
    /// shown emote. A memory warning and the background cut feed media and
    /// leave every shown emote resident; only a critical warning takes them.
    @Test func feedMediaGoesBeforeEmotesUnderMemoryPressure() {
        let coordinator = makeCoordinator()
        let registry = UIAssetCaches()
        registry.attach(to: coordinator)
        let engine = makeEngine(registry: registry)
        let decoded = feed("feed.decoded")
        coordinator.register(decoded)

        decoded.insert(Data(count: 10), for: "prefetched", cost: 10, tier: .speculative)
        for index in 0..<4 { decoded.insert(Data(count: 10), for: "seen\(index)", cost: 10) }
        let shown = emotes(3)
        for emote in shown {
            engine.insert(EmoteLabelTests.syntheticArt(side: 64), for: emote, pixelSide: 64, motion: .loop)
        }
        let cached = { shown.filter { engine.memory.contains("\($0.id)@64") }.count }
        #expect(engine.memory.usage.bytesByTier[.recent] ?? 0 > 0, "a shown emote is `recent`")
        #expect(coordinator.registeredCaches.contains { $0 === engine.memory })

        coordinator.trim(.memoryWarning)
        #expect(!decoded.contains("prefetched"))
        #expect(decoded.usage.count == 2, "half the seen feed media went")
        #expect(cached() == 3, "every emote stayed")

        coordinator.trim(.background)
        #expect(decoded.usage.count == 0, "every recent feed entry went")
        #expect(cached() == 3, "every emote stayed")

        coordinator.trim(.memoryCritical)
        #expect(cached() == 0, "a critical warning takes them")
    }

    /// THE FLOOR: the 64 MB disk namespace holds while the feed's image
    /// namespace churns through the rest of the pool, and on a low disk.
    @Test func theDiskFloorHoldsUnderPressureFromOtherNamespaces() async throws {
        // Images pool 72 MB (a third of 216): 64 reserved for UI assets, 8 for
        // the feed.
        let coordinator = makeCoordinator(limit: .total(bytes: 216_000_000))
        let registry = UIAssetCaches()
        registry.attach(to: coordinator)
        let store = try UIAssetCaches.openDisk(root: root)
        let engine = makeEngine(registry: registry, disk: store)
        let images = try DiskStore(
            namespace: CacheNamespace("images", category: .images, scope: .public, priorityClass: .standard),
            budget: DiskBudget(pool: .images), root: root
        )
        coordinator.register(images)
        // Registered on the main thread, disk budgets land on the
        // coordinator's queue (#898).
        coordinator.waitForDiskWork()
        #expect(store.limits.bytes == 64 * CacheBytes.megabyte)
        #expect(images.limits.bytes == 8 * CacheBytes.megabyte)

        let disk = EmoteDiskCache { store }
        let seeded = emotes(5)
        let stems = seeded.map { EmoteDiskCache.fileStem(emoteID: $0.id, side: 64, still: false) }
        guard case .sheet(let sheet) = EmoteLabelTests.syntheticArt(side: 64) else { return }
        for stem in stems { disk.store(sheet, gutter: 2, stem: stem) }
        #expect(stems.allSatisfy(disk.contains))

        // The feed writes three times its share.
        for index in 0..<24 { try images.write(Data(count: CacheBytes.megabyte), for: "photo\(index)") }
        #expect(images.usage.bytes <= 8 * CacheBytes.megabyte)
        #expect(images.statistics.evictions >= 16, "the feed evicted its own entries")
        #expect(stems.allSatisfy(disk.contains), "the feed never reclaimed the floor")
        #expect(store.limits.bytes == 64 * CacheBytes.megabyte)

        // A new launch's engine reads every sheet back instead of baking.
        let next = EmoteEngine(diskCache: disk, animationProvider: { _ in nil })
        for emote in seeded {
            #expect(await next.art(for: emote, pixelSide: 64) != nil, "\(emote.id)")
        }
        #expect(next.stats.diskHits == seeded.count)
        #expect(next.stats.bakesStarted == 0)
        withExtendedLifetime(engine) {}
    }

    /// A LOGOUT KEEPS UI ASSETS: they are public and addressed by content.
    /// Viewer-scoped caches are wiped next to them.
    @Test func aLogoutKeepsEmotesInMemoryAndOnDisk() throws {
        let coordinator = makeCoordinator()
        let registry = UIAssetCaches()
        registry.attach(to: coordinator)
        let store = try UIAssetCaches.openDisk(root: root)
        let engine = makeEngine(registry: registry, disk: store)
        let viewer = feed("feed.viewer", scope: .viewer)
        coordinator.register(viewer)
        viewer.insert(Data(count: 10), for: "my-post", cost: 10)

        let emote = emotes(1)[0]
        engine.insert(EmoteLabelTests.syntheticArt(side: 64), for: emote, pixelSide: 64, motion: .loop)
        let disk = EmoteDiskCache { store }
        guard case .sheet(let sheet) = EmoteLabelTests.syntheticArt(side: 64) else { return }
        disk.store(sheet, gutter: 2, stem: "kept@64")

        coordinator.handle(.viewerChanged)
        #expect(!viewer.contains("my-post"), "the viewer's own data went")
        #expect(engine.cachedArt(for: emote, pixelSide: 64, motion: .loop) != nil)
        #expect(disk.contains(stem: "kept@64"))
    }

    /// A sheet the engine bakes is written through the namespace, read back by
    /// a new engine, and survives the Settings clear only until it runs.
    @Test func bakedSheetsGoThroughTheNamespace() async throws {
        let store = try UIAssetCaches.openDisk(root: root)
        let disk = EmoteDiskCache { store }
        let first = EmoteEngine(diskCache: disk)
        first.bakeDelay = .zero
        let heart = try #require(EmoteCatalog.shared.emote(id: "noto:2764_fe0f"))
        _ = try #require(await first.art(for: heart, pixelSide: 48))
        let stem = EmoteDiskCache.fileStem(emoteID: heart.id, side: 48, still: false)
        try #require(await settle { disk.contains(stem: stem) }, "the sheet reached the disk")
        #expect(store.usage.count == 1)
        #expect(store.contains(EmoteDiskCache.key(stem: stem)))

        store.removeAll()
        #expect(!disk.contains(stem: stem))
        let second = EmoteEngine(diskCache: disk, animationProvider: { _ in nil })
        second.bakeDelay = .zero
        #expect(await second.art(for: heart, pixelSide: 48) == nil, "cleared, and nothing to bake from")
        #expect(second.stats.diskHits == 0)
    }

    /// The glyph stills a text view draws before the art are a UI asset cache
    /// too (#894): a byte-budgeted `MemoryCache` of the class, announced to the
    /// shared registry, so the coordinator trims them instead of `NSCache`'s
    /// own guesses. A still is drawn once per glyph and size.
    @Test func glyphStillsAreAUIAssetCache() throws {
        let stills = EmoteAttachment.stills
        #expect(stills.namespace.priorityClass == .persistent)
        #expect(stills.namespace.scope == .public)
        #expect(stills.memoryBudget == EmoteAttachment.stillsBudget)
        #expect(UIAssetCaches.shared.caches.contains { $0 === stills }, "the stills are not announced to the registry")

        let heart = try #require(EmoteCatalog.shared.emote(id: "noto:2764_fe0f"))
        let side: CGFloat = 23.25
        let first = EmoteAttachment.still(of: heart, side: side)
        #expect(stills.usage.bytes > 0)
        #expect(EmoteAttachment.still(of: heart, side: side) === first, "the same still was drawn twice")

        stills.removeAll()
        #expect(EmoteAttachment.still(of: heart, side: side) !== first, "a cleared still was still served")
    }
}
