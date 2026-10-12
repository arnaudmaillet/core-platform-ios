import CacheKit
import Foundation
import Testing
@testable import StickerKit

/// Baked strips live in the device cache's UI assets class (#971): a memory
/// warning and the background keep them, a critical warning takes them, and a
/// logout never does. The coordinator decides, not a notification observer.
@MainActor
struct StickerStripCacheTests {
    private func makeCoordinator() -> CacheCoordinator {
        CacheCoordinator(device: CacheDevice(physicalMemory: { 6 << 30 }, availableDiskCapacity: { 100_000_000_000 }))
    }

    @Test func stripsAreUIAssetsKeptUntilACriticalWarning() async throws {
        let coordinator = makeCoordinator()
        let registry = UIAssetCaches()
        registry.attach(to: coordinator)
        let baker = StickerFrameBaker(registry: registry)
        #expect(baker.strips.namespace == UIAssetCaches.namespace("UIAssets.stickers"))
        #expect(coordinator.registeredCaches.contains { $0 === baker.strips })
        #expect(baker.strips.limits.bytes == 48 << 20)

        let noEntry = try #require(StickerCatalog.sticker(id: "NoEntry"))
        let strip = try #require(await baker.strip(for: noEntry, side: 32, motion: .still))
        #expect(baker.strips.usage.bytes == StickerFrameBaker.cost(of: strip))

        coordinator.trim(.memoryWarning)
        coordinator.trim(.background)
        coordinator.handle(.viewerChanged)
        #expect(await baker.strip(for: noEntry, side: 32, motion: .still) === strip, "kept, not baked again")
        #expect(baker.bakes == 1)

        coordinator.trim(.memoryCritical)
        #expect(baker.strips.usage.count == 0)
        let again = try #require(await baker.strip(for: noEntry, side: 32, motion: .still))
        #expect(again !== strip)
        #expect(baker.bakes == 2, "a critical warning took it; the next ask bakes again")
    }

    /// A baker made for one publish announces nothing: only the shared one's
    /// strips join the app's coordinator.
    @Test func onlyTheSharedBakerIsAnnounced() {
        // The shared baker first: it announces itself when it is made.
        let sharedStrips = StickerFrameBaker.shared.strips
        let baker = StickerFrameBaker()
        #expect(!UIAssetCaches.shared.caches.contains { $0 === baker.strips })
        #expect(UIAssetCaches.shared.caches.contains { $0 === sharedStrips })
    }
}
