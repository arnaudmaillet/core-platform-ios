import Foundation
import Testing
@testable import CacheKit

/// The UI assets class (#971): its policy, its disk namespace, and the
/// registry the kits announce their caches to. Every test builds its own
/// registry and folder; none touches `UIAssetCaches.shared` or `disk`.
final class UIAssetCachesTests {
    private let folder = TemporaryFolder()
    private let clock = ManualCacheClock()
    private let fake = FakeDevice()

    private func makeCoordinator(limit: CacheStorageLimit = .automatic) -> CacheCoordinator {
        CacheCoordinator(device: fake.device, storageLimit: limit)
    }

    // MARK: - Policy

    @Test func theClassIsPersistentPublicAndReservesItsDisk() throws {
        let namespace = UIAssetCaches.namespace("UIAssets.test")
        #expect(namespace.priorityClass == .persistent)
        #expect(namespace.scope == .public)
        #expect(!namespace.isWipedOnViewerChange, "a logout keeps UI assets")
        #expect(UIAssetCaches.diskBudget == .reserved(64 * megabyte, in: .images))
        #expect(UIAssetCaches.idleLifetime == 30 * 24 * 60 * 60)

        let store = try UIAssetCaches.openDisk(root: folder.url, clock: clock)
        #expect(store.namespace.name == UIAssetCaches.diskName)
        #expect(store.namespace.priorityClass == .persistent)
        // Bounded on its own, before any coordinator registers it.
        #expect(store.limits.bytes == 64 * megabyte)
    }

    /// A memory cache of the class holds to its budget on this device before
    /// a coordinator sets it.
    @Test func aMemoryCacheIsBoundedBeforeRegistration() {
        let cache: MemoryCache<String, String> = UIAssetCaches.memoryCache(
            "UIAssets.test", budget: .physicalMemoryFraction(0.01, minimum: 1_000, maximum: 1_000_000), physicalMemory: 50_000_000
        )
        #expect(cache.limits.bytes == 500_000)
        #expect(cache.namespace.priorityClass == .persistent)
    }

    /// Memory: what was shown survives a warning and the background, and goes
    /// only on a critical warning. Speculative entries go first, as in every
    /// class.
    @Test func shownAssetsStayUntilACriticalWarning() {
        let coordinator = makeCoordinator()
        let assets: MemoryCache<String, String> = UIAssetCaches.memoryCache("UIAssets.test", budget: .fixed(bytes: 1_000), clock: clock)
        coordinator.register(assets)
        assets.insert("prefetched", for: "p", cost: 10, tier: .speculative)
        assets.insert("shown", for: "s", cost: 10)
        assets.insert("kept", for: "k", cost: 10, tier: .retained)
        let lease = assets.lease("s")
        assets.insert("shown too", for: "s2", cost: 10)

        coordinator.trim(.memoryWarning)
        #expect(!assets.contains("p"))
        #expect(assets.contains("s2"))
        coordinator.trim(.background)
        #expect(assets.contains("s2"))
        coordinator.trim(.memoryCritical)
        #expect(!assets.contains("s2"), "a critical warning takes what was shown")
        #expect(assets.contains("s"), "…but never what is on screen (leased)")
        #expect(assets.contains("k"))
        withExtendedLifetime(lease) {}
    }

    /// Disk: an entry nobody used for 30 days expires; one used inside that
    /// window lives on.
    @Test func anIdleEntryExpiresAfterThirtyDays() throws {
        let coordinator = makeCoordinator()
        let store = try UIAssetCaches.openDisk(root: folder.url, clock: clock)
        coordinator.register(store)
        try store.write(bytes(100), for: "idle")
        try store.write(bytes(100), for: "used")
        clock.advance(by: 20 * 24 * 60 * 60)
        #expect(store.data(for: "used") != nil)
        clock.advance(by: 11 * 24 * 60 * 60)
        coordinator.trim(.background)
        #expect(!store.contains("idle"))
        #expect(store.contains("used"))
        clock.advance(by: 20 * 24 * 60 * 60)
        coordinator.trim(.background)
        #expect(!store.contains("used"))
    }

    /// Disk: the 64 MB floor holds at every Settings limit, on a low disk too;
    /// it shrinks only under 1 GB free, and an explicit clear empties it.
    @Test func theDiskFloorShrinksOnlyBelowOneGigabyteFree() throws {
        let coordinator = makeCoordinator()
        let store = try UIAssetCaches.openDisk(root: folder.url, clock: clock)
        let images = try DiskStore(
            namespace: namespace("images"), budget: DiskBudget(pool: .images), root: folder.url, clock: clock
        )
        coordinator.register(store)
        coordinator.register(images)
        try store.write(bytes(1_000), for: "sheet")
        for limit in CacheStorageLimit.choices {
            coordinator.setStorageLimit(limit)
            for pressure in [DiskPressure.normal, .low] {
                coordinator.trim(.lowDisk(pressure))
                #expect(store.limits.bytes == 64 * megabyte, "\(limit) \(pressure)")
                #expect(images.limits.bytes < coordinator.diskPoolBudgets.images, "the feed shares the rest")
            }
        }
        #expect(store.contains("sheet"))

        fake.setFreeDisk(Int64(800 * megabyte))
        #expect(coordinator.refreshDiskSpace() == .critical)
        #expect(store.limits.bytes < 64 * megabyte, "under 1 GB free the reservation gives way")
        #expect(store.contains("sheet"))

        coordinator.trim(.clear(nil))
        #expect(!store.contains("sheet"), "an explicit clear includes UI assets")
    }

    // MARK: - Registry

    @Test func announcedCachesJoinTheCoordinatorWhenItAttaches() {
        let registry = UIAssetCaches()
        let coordinator = makeCoordinator()
        let early: MemoryCache<String, String> = UIAssetCaches.memoryCache("UIAssets.early", budget: .fixed(bytes: 1_234))
        registry.adopt(early)
        #expect(coordinator.registeredCaches.isEmpty)

        registry.attach(to: coordinator)
        #expect(coordinator.registeredCaches.map(\.namespace.name) == ["UIAssets.early"])
        #expect(early.limits.bytes == 1_234)

        let late: MemoryCache<String, String> = UIAssetCaches.memoryCache("UIAssets.late", budget: .fixed(bytes: 99))
        registry.adopt(late)
        #expect(Set(coordinator.registeredCaches.map(\.namespace.name)) == ["UIAssets.early", "UIAssets.late"])
    }

    /// The registry never keeps a cache alive: one nobody holds is gone, and
    /// never handed to a coordinator that attaches later.
    @Test func theRegistryHoldsCachesWeakly() {
        let registry = UIAssetCaches()
        do {
            let transient: MemoryCache<String, String> = UIAssetCaches.memoryCache("UIAssets.transient", budget: .fixed(bytes: 10))
            registry.adopt(transient)
            #expect(registry.caches.count == 1)
        }
        #expect(registry.caches.isEmpty)
        let coordinator = makeCoordinator()
        registry.attach(to: coordinator)
        #expect(coordinator.registeredCaches.isEmpty)
    }
}
