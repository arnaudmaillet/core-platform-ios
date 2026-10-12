import CacheKit
import Foundation
import Synchronization

/// What the viewer did to, or is to, an entity — followed a person, saved a
/// post — in a memory cache of its own `viewer`-scoped namespace, so the
/// coordinator's `.viewerChanged` wipes it while the content stays
/// (`EntityStore`). A plain `MemoryCache` would wipe in silence; this one says
/// so, and every screen drawing one of these facts re-draws.
final class ViewerFacts<Key: Hashable & Sendable, Value: Sendable>: ManagedCache {
    let cache: MemoryCache<Key, Value>
    private let onWipe = Mutex<(@Sendable () -> Void)?>(nil)

    init(_ name: String, limit: Int, clock: any CacheClock) {
        cache = MemoryCache(
            namespace: CacheNamespace(name, category: .other, scope: .viewer, priorityClass: .preferred),
            budget: .fixed(bytes: limit),
            limits: CacheLimits(bytes: limit, speculativeShare: CacheCoordinator.speculativeShare),
            clock: clock
        )
    }

    func setOnWipe(_ action: @escaping @Sendable () -> Void) {
        onWipe.withLock { $0 = action }
    }

    var namespace: CacheNamespace { cache.namespace }
    var budget: CacheBudget { cache.budget }
    var usage: CacheUsage { cache.usage }
    func setLimits(_ limits: CacheLimits) { cache.setLimits(limits) }
    func trim(_ depth: TrimDepth) { cache.trim(depth) }

    func removeAll() {
        cache.removeAll()
        let action = onWipe.withLock { $0 }
        action?()
    }
}

/// Set once, read many times, from any thread.
final class Flag: Sendable {
    private let value = Atomic<Bool>(false)

    var isSet: Bool { value.load(ordering: .acquiring) }

    /// Sets the flag; true only for the call that set it.
    func set() -> Bool {
        value.compareExchange(expected: false, desired: true, ordering: .acquiringAndReleasing).exchanged
    }
}
