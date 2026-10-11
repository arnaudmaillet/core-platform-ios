import Foundation
import Synchronization

/// A byte-budgeted memory cache with priority tiers, leases and expiry.
///
/// Each entry has a byte cost and a tier (`CacheTier`). Over budget, the
/// cache evicts the least recently used `speculative` entry first, then
/// `recent`, then `retained`. A leased entry (`lease(_:)`) is `pinned`: never
/// evicted while leased. Unleased `speculative` bytes have their own cap
/// (`CacheLimits.speculativeBytes`), so prefetching never crowds out what was
/// seen; a speculative entry nobody used expires after 24 h.
///
/// ⚠️ A `Mutex`, NOT an `actor`, for the reason in `ImagePipeline.swift`: cell
/// configuration reads caches synchronously from UIKit, and an actor's
/// synchronous-looking calls from an inferred-main-actor subclass compile with
/// a mere warning and race the actor's own work. Every member here is
/// genuinely nonisolated, and every read and write of the state goes through
/// one lock. Nothing slow runs under it.
public final class MemoryCache<Key: Hashable & Sendable, Value: Sendable>: ManagedCache {
    public let namespace: CacheNamespace
    public let memoryBudget: MemoryBudget
    public var budget: CacheBudget { .memory(memoryBudget) }

    private let clock: any CacheClock
    private let speculativeLifetime: TimeInterval
    private let state: Mutex<State>

    /// - Parameters:
    ///   - limits: the limits until a coordinator sets them on registration.
    ///   - speculativeLifetime: how long an unused speculative entry lives.
    public init(
        namespace: CacheNamespace,
        budget: MemoryBudget,
        limits: CacheLimits = .unlimited,
        clock: any CacheClock = SystemCacheClock(),
        speculativeLifetime: TimeInterval = CacheTier.speculativeLifetime
    ) {
        self.namespace = namespace
        self.memoryBudget = budget
        self.clock = clock
        self.speculativeLifetime = speculativeLifetime
        state = Mutex(State(limits: limits))
    }

    // MARK: - Reading

    /// The value for `key`, as a USE: the entry becomes the most recently
    /// used of its tier, and a speculative entry is promoted to `recent`
    /// (shown, so it no longer expires). Counts a hit or a miss.
    public func value(for key: Key) -> Value? {
        let now = clock.now
        return mutate { state in
            guard var entry = state.entries[key] else {
                state.statistics.misses += 1
                return nil
            }
            if entry.leases == 0, entry.isExpired(at: now) {
                state.remove(key)
                state.statistics.expirations += 1
                state.statistics.misses += 1
                return nil
            }
            if entry.leases == 0 {
                if entry.tier == .speculative {
                    state.unlink(key, entry)
                    entry.promote()
                    state.link(key, entry)
                    state.entries[key] = entry
                } else {
                    state.lru.touch(key, tier: entry.tier)
                }
            }
            state.statistics.hits += 1
            return entry.value
        }
    }

    /// The value for `key` without counting as a use: no LRU move, no
    /// promotion, no statistics. For a prefetcher checking what is there.
    public func peek(_ key: Key) -> Value? {
        let now = clock.now
        return state.withLock { state in
            guard let entry = state.entries[key] else { return nil }
            if entry.leases == 0, entry.isExpired(at: now) { return nil }
            return entry.value
        }
    }

    public func contains(_ key: Key) -> Bool { peek(key) != nil }

    /// The tier `key` is stored with, `nil` if absent.
    public func tier(of key: Key) -> CacheTier? {
        state.withLock { $0.entries[key]?.tier }
    }

    /// Whether `key` is held by at least one lease.
    public func isLeased(_ key: Key) -> Bool {
        state.withLock { ($0.entries[key]?.leases ?? 0) > 0 }
    }

    // MARK: - Writing

    /// Stores `value` under `key`.
    ///
    /// Storing over an existing entry keeps the HIGHER of the two tiers (a
    /// prefetch never demotes something already seen) and keeps its leases.
    /// The entry being stored is never the victim of its own insert: older
    /// entries make room first. A `speculative` entry never displaces a
    /// `retained` one.
    ///
    /// - Parameter expiresAt: an absolute expiry on top of the speculative
    ///   one, e.g. a signed URL's `url_expires_at`.
    /// - Returns: `false` when the entry cannot fit (bigger than the budget,
    ///   or the room is held by leases or higher tiers); an existing entry is
    ///   then left as it was.
    @discardableResult
    public func insert(_ value: Value, for key: Key, cost: Int, tier: CacheTier = .recent, expiresAt: Date? = nil) -> Bool {
        store(value, for: key, cost: cost, tier: tier, expiresAt: expiresAt, leasing: false) != nil
    }

    /// Stores `value` and leases it in one step, so nothing can evict it in
    /// between. Never refused: a leased entry may exceed the budget.
    public func insertLeased(_ value: Value, for key: Key, cost: Int, tier: CacheTier = .recent, expiresAt: Date? = nil) -> CacheLease {
        let id = store(value, for: key, cost: cost, tier: tier, expiresAt: expiresAt, leasing: true)
        // A leased store always succeeds; the fallback only satisfies the type.
        return makeLease(key: key, id: id ?? .max)
    }

    /// Pins the entry for `key` (on screen, playing). A speculative entry is
    /// promoted to `recent`: being shown is a use. `nil` if absent or expired.
    public func lease(_ key: Key) -> CacheLease? {
        let now = clock.now
        let id: UInt64? = mutate { state in
            guard var entry = state.entries[key] else { return nil }
            if entry.leases == 0, entry.isExpired(at: now) {
                state.remove(key)
                state.statistics.expirations += 1
                return nil
            }
            state.unlink(key, entry)
            entry.promote()
            entry.leases += 1
            state.link(key, entry)
            state.entries[key] = entry
            return entry.id
        }
        return id.map { makeLease(key: key, id: $0) }
    }

    /// Moves `key` to `tier` (e.g. `retained` for the viewer's own avatar, or
    /// back to `recent` when it stops being the first page). Demoting to
    /// `speculative` restarts its 24 h.
    public func setTier(_ tier: CacheTier, for key: Key) {
        let now = clock.now
        mutate { state in
            guard var entry = state.entries[key] else { return }
            state.unlink(key, entry)
            entry.tier = tier
            entry.speculativeDeadline = tier == .speculative ? now.addingTimeInterval(speculativeLifetime) : nil
            state.link(key, entry)
            state.entries[key] = entry
            state.enforceLimits(protecting: nil, ceiling: .retained)
        }
    }

    /// Removes `key`, leased or not. A lease on it becomes a no-op.
    @discardableResult
    public func removeValue(for key: Key) -> Value? {
        mutate { $0.remove(key)?.value }
    }

    // MARK: - ManagedCache

    public func removeAll() {
        mutate { state in
            state.evicted.append(contentsOf: state.entries.values.map(\.value))
            state.entries.removeAll()
            state.lru.removeAll()
            state.tierBytes.removeAll()
            state.totalBytes = 0
            state.pinnedBytes = 0
        }
    }

    public func setLimits(_ limits: CacheLimits) {
        mutate { state in
            state.limits = limits
            state.enforceLimits(protecting: nil, ceiling: .retained)
        }
    }

    public func trim(_ depth: TrimDepth) {
        let now = clock.now
        mutate { state in
            let entries = state.entries
            let victims = state.lru.victims(
                for: depth,
                cost: { entries[$0]?.cost ?? 0 },
                isExpired: { entries[$0]?.isExpired(at: now) ?? false }
            )
            for key in victims {
                guard let removed = state.remove(key) else { continue }
                if removed.isExpired(at: now) {
                    state.statistics.expirations += 1
                } else {
                    state.statistics.evictions += 1
                }
            }
        }
    }

    public var usage: CacheUsage {
        state.withLock { state in
            CacheUsage(
                bytes: state.totalBytes,
                count: state.entries.count,
                pinnedBytes: state.pinnedBytes,
                bytesByTier: state.tierBytes.filter { $0.value > 0 },
                byteLimit: state.limits.bytes
            )
        }
    }

    public var limits: CacheLimits { state.withLock { $0.limits } }

    public var statistics: CacheStatistics { state.withLock { $0.statistics } }

    /// Unleased keys of `tier`, least recently used first.
    func orderedKeys(in tier: CacheTier) -> [Key] {
        state.withLock { $0.lru.list(tier).ordered }
    }

    // MARK: - Internals

    private func store(_ value: Value, for key: Key, cost rawCost: Int, tier: CacheTier, expiresAt: Date?, leasing: Bool) -> UInt64? {
        let cost = max(0, rawCost)
        let now = clock.now
        let lifetime = speculativeLifetime
        return mutate { state -> UInt64? in
            let existing = state.entries[key]
            let leasedAfter = leasing || (existing?.leases ?? 0) > 0
            let storedTier = max(existing?.tier ?? tier, tier)
            if !leasedAfter {
                if cost > state.limits.bytes { return nil }
                if storedTier == .speculative, cost > state.limits.speculativeBytes { return nil }
            }
            var entry: Entry
            if let existing {
                state.unlink(key, existing)
                state.evicted.append(existing.value)
                entry = existing
                entry.value = value
                entry.cost = cost
                entry.tier = storedTier
            } else {
                state.nextID += 1
                entry = Entry(value: value, cost: cost, tier: tier, leases: 0, id: state.nextID)
            }
            entry.expiresAt = expiresAt
            if tier == .speculative, entry.tier == .speculative {
                entry.speculativeDeadline = now.addingTimeInterval(lifetime)
            }
            if leasing {
                entry.promote()
                entry.leases += 1
            }
            state.link(key, entry)
            state.entries[key] = entry
            let kept = state.enforceLimits(protecting: key, ceiling: entry.tier == .speculative ? .recent : .retained)
            return kept ? entry.id : nil
        }
    }

    /// Runs a mutation under the lock. Values it removed or replaced are
    /// released AFTER the lock: a value whose deinit ends a lease (on this
    /// cache or another) must never run under it.
    @discardableResult
    private func mutate<R: Sendable>(_ body: (inout State) -> R) -> R {
        let (result, released) = state.withLock { state -> (R, [Value]) in
            let result = body(&state)
            let released = state.evicted
            state.evicted.removeAll()
            return (result, released)
        }
        withExtendedLifetime(released) {}
        return result
    }

    private func makeLease(key: Key, id: UInt64) -> CacheLease {
        CacheLease { [weak self] in self?.endLease(key: key, id: id) }
    }

    private func endLease(key: Key, id: UInt64) {
        mutate { state in
            // A lease on an entry that was removed or replaced by a wipe is a
            // no-op: the id no longer matches.
            guard var entry = state.entries[key], entry.id == id, entry.leases > 0 else { return }
            state.unlink(key, entry)
            entry.leases -= 1
            state.link(key, entry)
            state.entries[key] = entry
            if entry.leases == 0 {
                state.enforceLimits(protecting: nil, ceiling: .retained)
            }
        }
    }

    private struct Entry {
        var value: Value
        var cost: Int
        var tier: CacheTier
        var leases: Int
        let id: UInt64
        var speculativeDeadline: Date?
        var expiresAt: Date?

        init(value: Value, cost: Int, tier: CacheTier, leases: Int, id: UInt64) {
            self.value = value
            self.cost = cost
            self.tier = tier
            self.leases = leases
            self.id = id
        }

        func isExpired(at now: Date) -> Bool {
            if let expiresAt, expiresAt <= now { return true }
            if tier == .speculative, let speculativeDeadline, speculativeDeadline <= now { return true }
            return false
        }

        /// Shown: a speculative entry becomes `recent` and stops expiring.
        mutating func promote() {
            guard tier == .speculative else { return }
            tier = .recent
            speculativeDeadline = nil
        }
    }

    private struct State {
        var entries: [Key: Entry] = [:]
        /// Unleased entries only.
        var lru = TieredLRU<Key>()
        /// Unleased bytes per tier.
        var tierBytes: [CacheTier: Int] = [:]
        var totalBytes = 0
        var pinnedBytes = 0
        var limits: CacheLimits
        var nextID: UInt64 = 0
        var statistics = CacheStatistics()
        /// Values removed during the current mutation, released after the lock.
        var evicted: [Value] = []

        init(limits: CacheLimits) {
            self.limits = limits
        }

        /// Adds `entry`'s accounting: an LRU slot if unleased, pinned bytes if not.
        mutating func link(_ key: Key, _ entry: Entry) {
            totalBytes += entry.cost
            if entry.leases == 0 {
                lru.append(key, tier: entry.tier)
                tierBytes[entry.tier, default: 0] += entry.cost
            } else {
                pinnedBytes += entry.cost
            }
        }

        mutating func unlink(_ key: Key, _ entry: Entry) {
            totalBytes -= entry.cost
            if entry.leases == 0 {
                lru.remove(key, tier: entry.tier)
                tierBytes[entry.tier, default: 0] -= entry.cost
            } else {
                pinnedBytes -= entry.cost
            }
        }

        @discardableResult
        mutating func remove(_ key: Key) -> Entry? {
            guard let entry = entries.removeValue(forKey: key) else { return nil }
            unlink(key, entry)
            evicted.append(entry.value)
            return entry
        }

        /// Evicts to the limits. `protecting` (the entry being stored) goes
        /// last, and only if it cannot fit at all; `ceiling` is the highest
        /// tier it may displace.
        @discardableResult
        mutating func enforceLimits(protecting: Key?, ceiling: CacheTier) -> Bool {
            while tierBytes[.speculative, default: 0] > limits.speculativeBytes,
                  let victim = lru.victim(upTo: .speculative, excluding: protecting) {
                remove(victim)
                statistics.evictions += 1
            }
            while totalBytes > limits.bytes, let victim = lru.victim(upTo: ceiling, excluding: protecting) {
                remove(victim)
                statistics.evictions += 1
            }
            guard let protecting, let entry = entries[protecting], entry.leases == 0 else { return true }
            let overSpeculative = entry.tier == .speculative && tierBytes[.speculative, default: 0] > limits.speculativeBytes
            if overSpeculative || totalBytes > limits.bytes {
                remove(protecting)
                return false
            }
            return true
        }
    }
}
