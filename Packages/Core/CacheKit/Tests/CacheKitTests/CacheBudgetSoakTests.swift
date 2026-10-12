import Foundation
import Testing
@testable import CacheKit

/// A deterministic random source (SplitMix64), so a soak replays the same
/// load on every run and a failure names a step that can be reproduced.
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }
}

/// Budget soaks (#900): a scripted load through one coordinator, with an
/// injected clock and device, that checks after EVERY step that the budgets
/// hold:
///
/// - memory: no namespace holds more than its limit, unless all it holds is
///   pinned (a lease may exceed a budget; nothing evictable may);
/// - speculative bytes at or below each namespace's speculative cap;
/// - disk: every namespace within its limit, and every pool's namespaces
///   within the pool's budget for the current Settings limit and disk
///   pressure;
/// - pinned entries are never evicted: a held lease's entry is still served
///   until a wipe, and a leased file stays on disk until its lease ends;
/// - every cache's speculative bytes balance (stored = used + wasted +
///   discarded + held), so the waste ratio the audit logs is sound.
///
/// No sleep, no process-wide state: time moves on a `ManualCacheClock`, the
/// device is a `FakeDevice`, disk stores live in a private folder. The whole
/// suite runs in seconds, inside CI's limits.
final class CacheBudgetSoakTests {
    private let folder = TemporaryFolder()
    private let clock = ManualCacheClock()
    private let fake = FakeDevice()

    /// One cache of the soak, memory or disk, behind the few calls the script makes.
    private enum Target {
        case memory(MemoryCache<String, Int>)
        case disk(DiskStore)

        var managed: any ManagedCache {
            switch self {
            case .memory(let cache): cache
            case .disk(let store): store
            }
        }

        var name: String { managed.namespace.name }
        var limits: CacheLimits {
            switch self {
            case .memory(let cache): cache.limits
            case .disk(let store): store.limits
            }
        }

        var statistics: CacheStatistics { managed.statistics }

        func store(_ key: String, cost: Int, tier: CacheTier) {
            switch self {
            case .memory(let cache): cache.insert(cost, for: key, cost: cost, tier: tier)
            case .disk(let store): _ = try? store.write(bytes(cost), for: key, tier: tier)
            }
        }

        func read(_ key: String) {
            switch self {
            case .memory(let cache): _ = cache.value(for: key)
            case .disk(let store): _ = store.data(for: key)
            }
        }

        func lease(_ key: String) -> (lease: CacheLease, file: URL?)? {
            switch self {
            case .memory(let cache):
                return cache.lease(key).map { ($0, nil) }
            case .disk(let store):
                guard let lease = store.lease(key) else { return nil }
                return (lease, store.fileURL(for: key))
            }
        }

        func insertLeased(_ key: String, cost: Int) -> (lease: CacheLease, file: URL?)? {
            switch self {
            case .memory(let cache):
                return (cache.insertLeased(cost, for: key, cost: cost), nil)
            case .disk:
                return nil
            }
        }

        func setTier(_ tier: CacheTier, for key: String) {
            switch self {
            case .memory(let cache): cache.setTier(tier, for: key)
            case .disk(let store): store.setTier(tier, for: key)
            }
        }

        func isServedAndLeased(_ key: String) -> Bool {
            switch self {
            case .memory(let cache): cache.isLeased(key) && cache.contains(key)
            case .disk(let store): store.isLeased(key) && store.contains(key)
            }
        }

        var pool: DiskPool? {
            if case .disk(let budget) = managed.budget { return budget.pool }
            return nil
        }
    }

    private struct Held {
        let target: Int
        let key: String
        let lease: CacheLease
        let file: URL?
        /// False once a wipe took its namespace: the entry is no longer
        /// served, but a leased file stays on disk until the lease ends.
        var served = true
    }

    /// Checks every budget rule; returns what broke.
    private func violations(_ targets: [Target], _ held: [Held], _ coordinator: CacheCoordinator, step: Int) -> [String] {
        var broken: [String] = []
        var unpinnedByPool: [DiskPool: Int] = [:]
        var limitsByPool: [DiskPool: Int] = [:]
        for target in targets {
            let usage = target.managed.usage
            let limits = target.limits
            if usage.bytes > limits.bytes, usage.bytes != usage.pinnedBytes {
                broken.append("step \(step): \(target.name) holds \(usage.bytes) over its \(limits.bytes) with only \(usage.pinnedBytes) pinned")
            }
            let speculative = usage.bytesByTier[.speculative, default: 0]
            if speculative > limits.speculativeBytes {
                broken.append("step \(step): \(target.name) holds \(speculative) speculative over its cap \(limits.speculativeBytes)")
            }
            let fates = target.statistics.speculative
            if fates.storedBytes != fates.usedBytes + fates.wastedBytes + fates.discardedBytes + speculative {
                broken.append("step \(step): \(target.name) speculative bytes do not balance: \(fates)")
            }
            if let pool = target.pool {
                unpinnedByPool[pool, default: 0] += usage.bytes - usage.pinnedBytes
                limitsByPool[pool, default: 0] += limits.bytes
            }
        }
        let pools = coordinator.diskPoolBudgets
        for pool in DiskPool.allCases {
            if limitsByPool[pool, default: 0] > pools[pool] {
                broken.append("step \(step): \(pool) namespaces were given \(limitsByPool[pool, default: 0]) over the pool's \(pools[pool])")
            }
            if unpinnedByPool[pool, default: 0] > pools[pool] {
                broken.append("step \(step): \(pool) holds \(unpinnedByPool[pool, default: 0]) unpinned over the pool's \(pools[pool])")
            }
        }
        for lease in held {
            if lease.served, !targets[lease.target].isServedAndLeased(lease.key) {
                broken.append("step \(step): pinned \(targets[lease.target].name)/\(lease.key) was evicted")
            }
            if let file = lease.file, !FileManager.default.fileExists(atPath: file.path) {
                broken.append("step \(step): the leased file of \(targets[lease.target].name)/\(lease.key) is gone")
            }
        }
        return broken
    }

    // MARK: - Every namespace, every signal

    @Test func aScriptedLoadThroughTheCoordinatorKeepsEveryBudget() throws {
        var random = SeededGenerator(seed: 900)
        // 9 MB split 3:5:1: images 3 MB, video 5 MB, LocalStore 1 MB.
        let limits: [CacheStorageLimit] = [.total(bytes: 9 * megabyte), .total(bytes: 4_500_000), .total(bytes: 18 * megabyte)]
        let coordinator = CacheCoordinator(device: fake.device, storageLimit: limits[0])

        func memory(_ name: String, _ bytes: Int, scope: CacheScope = .public, category: CacheCategory = .images, _ priorityClass: CachePriorityClass) -> Target {
            .memory(MemoryCache(namespace: namespace(name, category, scope: scope, priorityClass: priorityClass), budget: .fixed(bytes: bytes), clock: clock))
        }
        func disk(_ name: String, _ budget: DiskBudget, scope: CacheScope = .public, category: CacheCategory = .images, _ priorityClass: CachePriorityClass = .standard) throws -> Target {
            .disk(try DiskStore(namespace: namespace(name, category, scope: scope, priorityClass: priorityClass), budget: budget, root: folder.url, clock: clock, flushThreshold: 64))
        }
        let targets: [Target] = [
            memory("images.decoded", 2_000_000, .standard),
            memory("images.decoded.small", 500_000, .preferred),
            memory("emotes", 300_000, category: .other, .persistent),
            memory("entities", 200_000, scope: .viewer, category: .other, .expendable),
            try disk("UIAssets", .reserved(400_000, in: .images), category: .other, .persistent),
            try disk("images", DiskBudget(pool: .images, weight: 3)),
            try disk("images.signed", DiskBudget(pool: .images, weight: 1), scope: .signed),
            try disk("video", DiskBudget(pool: .video), category: .videos),
            try disk("localstore", DiskBudget(pool: .localStore), scope: .viewer, category: .other)
        ]
        for target in targets { coordinator.register(target.managed) }

        let freeDisk: [Int64] = [100 * Int64(CacheBytes.gigabyte), 3 * Int64(CacheBytes.gigabyte), 500_000_000]
        let categories: [CacheCategory?] = [nil, .images, .videos, .other]
        var held: [Held] = []
        var lastStored: [Int: String] = [:]
        var wipedLeasedFiles = 0
        var broken: [String] = []
        let steps = 3_000

        for step in 0..<steps {
            let index = Int.random(in: 0..<targets.count, using: &random)
            let target = targets[index]
            let key = "k\(Int.random(in: 0..<120, using: &random))"
            // Costs up to an eighth of the namespace's current limit, so a
            // few entries fill it and evictions are frequent.
            let ceiling = max(1_000, min(target.limits.bytes, 18 * megabyte) / 8)
            let cost = Int.random(in: 1...ceiling, using: &random)
            let roll = Int.random(in: 0..<1_000, using: &random)
            switch roll {
            case 0..<460:
                let tierRoll = Int.random(in: 0..<100, using: &random)
                let tier: CacheTier = tierRoll < 40 ? .speculative : (tierRoll < 85 ? .recent : .retained)
                target.store(key, cost: cost, tier: tier)
                lastStored[index] = key
                // A disk lease pins a FILE (`DiskStore`): a write over a
                // leased key leaves the old file to its readers and stores an
                // ordinary entry. A memory lease stays on its key.
                if target.pool != nil {
                    for position in held.indices where held[position].target == index && held[position].key == key {
                        held[position].served = false
                    }
                }
            case 460..<660:
                target.read(key)
            case 660..<740:
                // Half the time the entry just stored, so leases (and the
                // wipes that take leased entries) are frequent on disk too.
                let leased = Bool.random(using: &random) ? (lastStored[index] ?? key) : key
                if let lease = target.lease(leased) {
                    held.append(Held(target: index, key: leased, lease: lease.lease, file: lease.file))
                }
            case 740..<760:
                if let lease = target.insertLeased(key, cost: cost) {
                    held.append(Held(target: index, key: key, lease: lease.lease, file: lease.file))
                }
            case 760..<830:
                if !held.isEmpty {
                    held.remove(at: Int.random(in: 0..<held.count, using: &random)).lease.release()
                }
            case 830..<845:
                target.setTier(Bool.random(using: &random) ? .retained : .recent, for: key)
            case 845..<865:
                coordinator.handle(.memoryWarning)
            case 865..<875:
                coordinator.handle(.memoryCritical)
            case 875..<895:
                coordinator.handle(.didEnterBackground)
            case 895..<915:
                fake.setFreeDisk(freeDisk[Int.random(in: 0..<freeDisk.count, using: &random)])
                coordinator.handle(.willEnterForeground)
            case 915..<925:
                coordinator.setStorageLimit(limits[Int.random(in: 0..<limits.count, using: &random)])
            case 925..<935:
                coordinator.handle(.viewerChanged)
                for position in held.indices where targets[held[position].target].managed.namespace.isWipedOnViewerChange {
                    held[position].served = false
                    if held[position].file != nil { wipedLeasedFiles += 1 }
                }
            case 935..<940:
                let category = categories[Int.random(in: 0..<categories.count, using: &random)]
                coordinator.trim(.clear(category))
                for position in held.indices where category == nil || targets[held[position].target].managed.namespace.category == category {
                    held[position].served = false
                    if held[position].file != nil { wipedLeasedFiles += 1 }
                }
            default:
                clock.advance(by: TimeInterval(Int.random(in: 600...(30 * 3_600), using: &random)))
            }
            broken += violations(targets, held, coordinator, step: step)
            if broken.count > 20 { break }
        }
        for lease in held { lease.lease.release() }
        held.removeAll()
        broken += violations(targets, held, coordinator, step: steps)
        #expect(broken.isEmpty, "\(broken.prefix(20).joined(separator: "\n"))")

        // The script reached every release path, and each counted under its reason.
        var removals: [CacheEvictionReason: Int] = [:]
        for target in targets {
            removals.merge(target.statistics.removals, uniquingKeysWith: +)
        }
        for reason in [CacheEvictionReason.budget, .memoryWarning, .memoryCritical, .background, .lowDisk, .viewerChanged, .clear, .expiry] {
            #expect(removals[reason, default: 0] > 0, "no removal counted as \(reason)")
        }
        let speculative = coordinator.usage().speculative()
        #expect(speculative.stored > 0 && speculative.used > 0 && speculative.wasted > 0)
        #expect(wipedLeasedFiles > 0, "a wipe took a namespace while one of its files was leased")
        DiskStore.drainJanitor()
    }

    // MARK: - Five minutes of feed images

    /// Five minutes of scrolling, replayed on the decoded image namespaces as
    /// #894 registers them (`images.decoded` standard, `images.decoded.small`
    /// preferred) on a 4 GB device, with the costs of real decodes: two
    /// minutes of the For You grid (402×536 px tiles, the next screen decoded
    /// ahead), then three minutes of the full-screen feed (1206×2622 px, the
    /// next post decoded ahead), a memory warning and a trip to the
    /// background. Checked every 100 ms of virtual time.
    @Test func fiveMinutesOfFeedImagesStayWithinTheDecodedBudget() {
        var random = SeededGenerator(seed: 894)
        let coordinator = CacheCoordinator(device: fake.device)
        let decoded = MemoryCache<String, Int>(
            namespace: CacheNamespace("images.decoded", category: .images, scope: .public, priorityClass: .standard),
            budget: .decodedImages,
            clock: clock
        )
        let small = MemoryCache<String, Int>(
            namespace: CacheNamespace("images.decoded.small", category: .images, scope: .public, priorityClass: .preferred),
            budget: .physicalMemoryFraction(0.01, minimum: 16 * CacheBytes.mebibyte, maximum: 48 * CacheBytes.mebibyte),
            clock: clock
        )
        coordinator.register(decoded)
        coordinator.register(small)
        let budget = decoded.limits
        #expect(budget.bytes == Int(Double(4 << 30) * 0.05))

        let tileCost = 402 * 536 * 4
        let postCost = 1206 * 2622 * 4
        let avatarCost = 128 * 128 * 4
        let columns = 3
        let visibleRows = 5
        let authors = 60

        var pinned: [String: CacheLease] = [:]
        var pinnedAvatars: [String: CacheLease] = [:]
        var broken: [String] = []
        var peak = 0

        /// What a visible image found, as the pipeline will report it.
        func show(_ key: String, cost: Int) -> CacheLease {
            if decoded.value(for: key) != nil, let lease = decoded.lease(key) {
                coordinator.prefetchCounters.recordArrival(.images, .ready)
                return lease
            }
            coordinator.prefetchCounters.recordArrival(.images, .missed)
            return decoded.insertLeased(cost, for: key, cost: cost)
        }
        func showAvatar(_ author: Int) -> CacheLease {
            let key = "avatar-\(author)"
            if small.value(for: key) != nil, let lease = small.lease(key) { return lease }
            return small.insertLeased(avatarCost, for: key, cost: avatarCost)
        }
        /// Keeps exactly `keys` pinned in `cache`'s lease table.
        func pin(_ keys: [String: Int], in table: inout [String: CacheLease], show: (String, Int) -> CacheLease) {
            for (key, lease) in table where keys[key] == nil {
                lease.release()
                table[key] = nil
            }
            for (key, cost) in keys where table[key] == nil {
                table[key] = show(key, cost)
            }
        }
        func prefetch(_ key: String, cost: Int) {
            if !decoded.contains(key) {
                decoded.insert(cost, for: key, cost: cost, tier: .speculative)
            }
        }

        var topRow = 0
        var gridMoves = 0
        var post = 0
        var nextMove: TimeInterval = 0
        let tick: TimeInterval = 0.1
        let ticks = Int(300 / tick)
        for step in 0...ticks {
            let now = Double(step) * tick
            if step > 0 { clock.advance(by: tick) }
            if now >= nextMove {
                if now < 120 {
                    // The grid: a row every 1.2 s, three rows back in every 20.
                    gridMoves += 1
                    topRow = max(0, topRow + (gridMoves % 20 >= 17 ? -1 : 1))
                    nextMove = now + 1.2
                    let visible = (topRow..<(topRow + visibleRows)).flatMap { row in (0..<columns).map { row * columns + $0 } }
                    pin(Dictionary(uniqueKeysWithValues: visible.map { ("tile-\($0)", tileCost) }), in: &pinned, show: show)
                    pin(Dictionary(uniqueKeysWithValues: Set(visible.map { $0 * 7 % authors }).map { ("avatar-\($0)", avatarCost) }),
                        in: &pinnedAvatars) { key, _ in showAvatar(Int(key.dropFirst("avatar-".count)) ?? 0) }
                    // The display window: the next screen, decoded ahead.
                    for row in (topRow + visibleRows)..<(topRow + 2 * visibleRows) {
                        for column in 0..<columns { prefetch("tile-\(row * columns + column)", cost: tileCost) }
                    }
                } else {
                    // The full-screen feed: a post every 1.5–5 s, one swipe
                    // back in ten.
                    post = Int.random(in: 0..<10, using: &random) == 0 ? max(0, post - 1) : post + 1
                    nextMove = now + Double.random(in: 1.5...5, using: &random)
                    pin(["post-\(post)": postCost], in: &pinned, show: show)
                    pin(["avatar-\(post * 7 % authors)": avatarCost], in: &pinnedAvatars) { key, _ in
                        showAvatar(Int(key.dropFirst("avatar-".count)) ?? 0)
                    }
                    prefetch("post-\(post + 1)", cost: postCost)
                }
            }
            if step == 2_000 { coordinator.handle(.memoryWarning) }
            if step == 2_500 { coordinator.handle(.didEnterBackground) }
            if step == 2_550 { coordinator.handle(.willEnterForeground) }

            for cache in [decoded, small] {
                let usage = cache.usage
                let limits = cache.limits
                if usage.bytes > limits.bytes, usage.bytes != usage.pinnedBytes {
                    broken.append("t=\(now): \(cache.namespace.name) holds \(usage.bytes) over \(limits.bytes)")
                }
                if usage.bytesByTier[.speculative, default: 0] > limits.speculativeBytes {
                    broken.append("t=\(now): \(cache.namespace.name) speculative over its cap")
                }
            }
            for key in pinned.keys where !(decoded.isLeased(key) && decoded.contains(key)) {
                broken.append("t=\(now): on-screen \(key) was evicted")
            }
            for key in pinnedAvatars.keys where !(small.isLeased(key) && small.contains(key)) {
                broken.append("t=\(now): on-screen \(key) was evicted")
            }
            peak = max(peak, decoded.usage.bytes)
            if broken.count > 20 { break }
        }
        for lease in Array(pinned.values) + Array(pinnedAvatars.values) { lease.release() }

        #expect(broken.isEmpty, "\(broken.prefix(20).joined(separator: "\n"))")
        #expect(peak <= budget.bytes, "the decoded images never went past \(budget.bytes) bytes (peak \(peak))")
        #expect(peak > budget.bytes / 2, "the load filled the budget, so the soak tested it (peak \(peak))")

        let statistics = decoded.statistics
        #expect(statistics.removals[.budget, default: 0] > 0)
        #expect(statistics.removals[.memoryWarning, default: 0] > 0)
        #expect(statistics.removals[.background, default: 0] > 0)
        let fates = statistics.speculative
        #expect(fates.storedBytes == fates.usedBytes + fates.wastedBytes + fates.discardedBytes + decoded.usage.bytesByTier[.speculative, default: 0])
        // Prefetching one screen ahead pays: nearly every image was ready on
        // arrival, and little of what was decoded ahead went unused.
        let arrivals = coordinator.prefetchCounters.snapshot.arrivals[.images] ?? CachePrefetchCounters.Arrivals()
        #expect((arrivals.hitRate ?? 0) >= 0.9, "hit rate \(arrivals)")
        #expect((fates.wasteRatio ?? 1) <= 0.1, "waste \(fates)")
        #expect((small.statistics.hitRate ?? 0) > 0.5, "avatars repeat across posts and stay")
    }
}
