import Foundation
import Synchronization

/// The UI assets class (#971): baked emote sheets, sticker strips, animated
/// icons and the flag palette. Small, reused on every screen, and costly to
/// bake again, so they are the namespaces the device cache keeps LONGEST.
///
/// - **Class:** `persistent`. A memory warning or the background takes only
///   their speculative entries; what was shown (`recent`) stays until a
///   CRITICAL warning, after feed media (`standard`) and avatars (`preferred`)
///   have been cut (`CachePriorityClass.depth(for:)`).
/// - **Scope:** `public`. The art is the same for every viewer and addressed
///   by content, so a logout or an account switch keeps it.
/// - **Disk:** one namespace, `UIAssets`, capped at 64 MB with those 64 MB
///   reserved in the images pool (`DiskBudget.reserved`). Pressure from the
///   other image namespaces never reclaims it; it shrinks only when the pool
///   itself falls under it (under 1 GB free) or on an explicit clear. An entry
///   nobody used for 30 days expires.
///
/// The kits create their caches through here, and announce the shared ones to
/// a registry (`UIAssetCaches.shared`). The app attaches its coordinator to
/// that registry once (`attach(to:)`), so every cache a kit made before or
/// after joins the coordinator's budgets and trims. A test builds its own
/// registry, and never touches the shared one.
public final class UIAssetCaches: Sendable {
    /// The registry the kits' shared caches announce themselves to.
    public static let shared = UIAssetCaches()

    // MARK: - Policy

    /// The disk namespace's name, a folder under `Caches`.
    public static let diskName = "UIAssets"
    /// Bump when the meaning of the bytes behind a key changes for EVERY kit;
    /// a kit that changes its own format versions its keys instead.
    public static let diskVersion = 1
    /// The disk cap, reserved in full (a proposal, #971).
    public static let diskReservedBytes = 64 * CacheBytes.megabyte
    public static let diskBudget = DiskBudget.reserved(diskReservedBytes, in: .images)
    /// An entry nobody used for this long expires: 30 days.
    public static let idleLifetime: TimeInterval = 30 * 24 * 60 * 60

    /// The namespace of one UI asset cache. Names are unique per medium: the
    /// coordinator replaces a cache registered under a name already taken.
    ///
    /// - Parameter priorityClass: `persistent`, the class's own. A kit cache
    ///   that shares a UI asset's type but holds feed media (the map's preview
    ///   sheets, cut from posts' clips) passes `standard`, so it goes with the
    ///   feed under pressure.
    public static func namespace(_ name: String, priorityClass: CachePriorityClass = .persistent) -> CacheNamespace {
        CacheNamespace(name, category: .other, scope: .public, priorityClass: priorityClass)
    }

    /// A memory cache of the class. Until a coordinator registers it, it holds
    /// to its budget on this device, so a kit used without one stays bounded.
    public static func memoryCache<Key: Hashable & Sendable, Value: Sendable>(
        _ name: String,
        budget: MemoryBudget,
        priorityClass: CachePriorityClass = .persistent,
        physicalMemory: UInt64 = ProcessInfo.processInfo.physicalMemory,
        clock: any CacheClock = SystemCacheClock()
    ) -> MemoryCache<Key, Value> {
        let bytes = budget.bytes(physicalMemory: physicalMemory)
        return MemoryCache(
            namespace: namespace(name, priorityClass: priorityClass),
            budget: budget,
            limits: CacheLimits(bytes: bytes, speculativeShare: CacheCoordinator.speculativeShare),
            clock: clock
        )
    }

    /// Opens the UI assets disk namespace under `root` (the app's `Caches` by
    /// default). Open it ONCE per folder per process (`DiskStore`): the app
    /// reads `disk`, a test passes a folder of its own.
    public static func openDisk(root: URL? = nil, clock: any CacheClock = SystemCacheClock()) throws -> DiskStore {
        try DiskStore(
            namespace: namespace(diskName),
            version: diskVersion,
            budget: diskBudget,
            root: root,
            limits: CacheLimits(bytes: diskReservedBytes, speculativeShare: CacheCoordinator.speculativeShare),
            clock: clock,
            idleLifetime: idleLifetime
        )
    }

    /// The app's UI assets disk namespace, opened on first touch and announced
    /// to `shared`. Opening reads the index and reconciles it with the files:
    /// touch it off the main thread first (the app does, in
    /// `startCacheCoordinator()`). Nil only if the folder cannot be created;
    /// every asset is then simply rebuilt.
    public static let disk: DiskStore? = {
        let store = try? openDisk()
        if let store { shared.adopt(store) }
        diskOpened.store(true, ordering: .releasing)
        return store
    }()

    /// Whether `disk` has finished opening, by any caller: what the main
    /// thread asks before it reads `disk` (#898, from #986's review). Reading
    /// `disk` before then would open it there, or wait there for the open in
    /// flight, since a lazy static blocks its readers.
    public static var isDiskOpen: Bool { diskOpened.load(ordering: .acquiring) }

    /// `disk` once open; nil while it is not (never opens it).
    public static var diskIfOpen: DiskStore? { isDiskOpen ? disk : nil }

    private static let diskOpened = Atomic<Bool>(false)

    // MARK: - Registry

    private struct Member {
        weak var cache: (any ManagedCache)?
    }

    private struct State {
        var members: [Member] = []
        var coordinator: CacheCoordinator?
    }

    private let state = Mutex(State())

    public init() {}

    /// Announces `cache`. Registered with the attached coordinator at once, or
    /// when one attaches. Held weakly until then: a cache nobody keeps is
    /// never resurrected by the registry.
    public func adopt(_ cache: any ManagedCache) {
        let coordinator = state.withLock { state -> CacheCoordinator? in
            state.members.removeAll { $0.cache == nil || $0.cache === cache }
            state.members.append(Member(cache: cache))
            return state.coordinator
        }
        coordinator?.register(cache)
    }

    /// Hands every announced cache, and every later one, to `coordinator`.
    public func attach(to coordinator: CacheCoordinator) {
        let caches = state.withLock { state -> [any ManagedCache] in
            state.coordinator = coordinator
            state.members.removeAll { $0.cache == nil }
            return state.members.compactMap(\.cache)
        }
        for cache in caches { coordinator.register(cache) }
    }

    /// The caches announced so far that are still alive.
    public var caches: [any ManagedCache] {
        state.withLock { $0.members.compactMap(\.cache) }
    }
}
