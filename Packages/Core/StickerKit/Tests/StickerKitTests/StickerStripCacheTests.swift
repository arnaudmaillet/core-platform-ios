import CacheKit
import Foundation
import Testing
import UIKit
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

    /// Chat's first frames were an `NSCache` no signal of the device cache
    /// reached (#898): now a UI asset namespace, announced to the shared
    /// registry the app attaches its coordinator to, so the class's trims
    /// (`CachePriorityClass.persistent`, CacheKit's tests) and the budget
    /// apply. Not trimmed here: the cache is the process's own, and a
    /// neighbouring suite reads it.
    @Test func firstFramesAreAUIAssetNamespaceTheCoordinatorManages() async throws {
        let frames = StickerCatalog.frameCache
        #expect(frames.namespace == UIAssetCaches.namespace("UIAssets.stickerFrames"))
        #expect(frames.namespace.priorityClass == .persistent)
        #expect(UIAssetCaches.shared.caches.contains { $0 === frames })
        #expect(frames.limits.bytes == 8 << 20)

        let sticker = try #require(StickerCatalog.sticker(id: "NoEntry"))
        let size = CGSize(width: 37, height: 37)
        let first: UIImage? = await withCheckedContinuation { continuation in
            StickerCatalog.firstFrame(for: sticker, size: size) { continuation.resume(returning: $0) }
        }
        let image = try #require(first)
        #expect(frames.contains("NoEntry@37x37"))
        #expect(frames.usage.bytes >= StickerCatalog.cost(of: image), "counted in bytes against its budget")
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
