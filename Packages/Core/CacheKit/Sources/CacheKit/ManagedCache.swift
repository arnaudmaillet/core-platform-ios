import Foundation
import Synchronization

/// A cache the `CacheCoordinator` manages: it declares who it is and how its
/// budget follows the device, reports what it holds, and obeys the
/// coordinator's limits, trims and wipes.
///
/// `MemoryCache` and `DiskStore` conform. A store with its own storage (the
/// SQLite LocalStore of #893, the video byte cache of #895) conforms too, so
/// the coordinator sees every byte the app caches.
///
/// Every requirement may be called from any thread, and must never call back
/// into the coordinator.
public protocol ManagedCache: AnyObject, Sendable {
    var namespace: CacheNamespace { get }
    var budget: CacheBudget { get }
    var usage: CacheUsage { get }
    /// Evicts down to the new limits at once: speculative first, then recent,
    /// then retained, LRU within a tier, never a leased entry.
    func setLimits(_ limits: CacheLimits)
    func trim(_ depth: TrimDepth)
    /// The wipe of a logout or a Settings clear. Leased entries stop being
    /// served at once; their storage is freed when the last lease ends.
    func removeAll()
    /// Persists anything held only in memory (a disk index). Called when the
    /// app goes to the background.
    func flush()

    /// Lookup and eviction counters (`-cache-audit`, #900). Zero by default.
    var statistics: CacheStatistics { get }
    /// The coordinator's calls, with the signal behind them, so the cache can
    /// count its evictions per reason. By default they drop the reason and
    /// call `setLimits(_:)`, `trim(_:)` and `removeAll()`.
    func setLimits(_ limits: CacheLimits, reason: CacheEvictionReason)
    func trim(_ depth: TrimDepth, reason: CacheEvictionReason)
    func removeAll(reason: CacheEvictionReason)
    /// While paused, the cache admits no new unleased entry below `retained`
    /// (#898): the coordinator pauses the memory namespaces the background
    /// cut to `retained`, so what that trim released does not grow back
    /// before the foreground. Leased and retained stores still land. A no-op
    /// by default.
    func setAdmissionsPaused(_ paused: Bool)
}

extension ManagedCache {
    public var medium: CacheMedium { budget.medium }
    public func flush() {}
    public var statistics: CacheStatistics { CacheStatistics() }
    public func setLimits(_ limits: CacheLimits, reason: CacheEvictionReason) { setLimits(limits) }
    public func trim(_ depth: TrimDepth, reason: CacheEvictionReason) { trim(depth) }
    public func removeAll(reason: CacheEvictionReason) { removeAll() }
    public func setAdmissionsPaused(_ paused: Bool) {}
}

/// The time CacheKit reads for last access and expiry. Injected, so a test
/// moves time without sleeping and never touches a process-wide clock.
public protocol CacheClock: Sendable {
    var now: Date { get }
}

public struct SystemCacheClock: CacheClock {
    public init() {}
    public var now: Date { Date() }
}

/// A clock a test moves by hand.
public final class ManualCacheClock: CacheClock {
    private let current: Mutex<Date>

    public init(_ start: Date = Date(timeIntervalSinceReferenceDate: 800_000_000)) {
        current = Mutex(start)
    }

    public var now: Date { current.withLock { $0 } }

    public func advance(by interval: TimeInterval) {
        current.withLock { $0 = $0.addingTimeInterval(interval) }
    }
}

/// A registration that ends when cancelled or deallocated.
public final class CacheObservation: Sendable {
    private let lease: CacheLease

    init(onCancel: @escaping @Sendable () -> Void) {
        lease = CacheLease(onRelease: onCancel)
    }

    public func cancel() { lease.release() }
}

/// A claim that keeps one cache entry `pinned`: on screen, playing, being
/// uploaded. The entry is never evicted, by a budget or a trim, while any
/// lease on it is held.
///
/// Release it when the view or the player lets go. Releasing twice is
/// harmless, and a lease releases itself when it is deallocated, so a cell
/// that is torn down never pins an entry forever.
public final class CacheLease: Sendable {
    private let action: Mutex<(@Sendable () -> Void)?>

    init(onRelease: @escaping @Sendable () -> Void) {
        action = Mutex(onRelease)
    }

    public var isReleased: Bool { action.withLock { $0 == nil } }

    public func release() {
        let pending = action.withLock { stored -> (@Sendable () -> Void)? in
            let taken = stored
            stored = nil
            return taken
        }
        pending?()
    }

    deinit { release() }
}
