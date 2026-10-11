import Foundation
import Testing
@testable import CacheKit

/// The memory cache's budget, tier order, LRU, leases and expiry (#891).
struct MemoryCacheTests {
    @Test func byteBudgetIsEnforced() {
        let cache = memoryCache(limit: 100)
        for index in 0..<10 {
            #expect(cache.insert("v\(index)", for: "k\(index)", cost: 20))
        }
        #expect(cache.usage.bytes == 100)
        #expect(cache.usage.count == 5)
        #expect((0..<5).allSatisfy { !cache.contains("k\($0)") }, "the oldest went first")
        #expect((5..<10).allSatisfy { cache.contains("k\($0)") })
    }

    @Test func anEntryBiggerThanTheBudgetIsRefusedAndTheOldOneKept() {
        let cache = memoryCache(limit: 100)
        cache.insert("small", for: "a", cost: 10)
        #expect(!cache.insert("huge", for: "a", cost: 101))
        #expect(cache.peek("a") == "small")
        #expect(!cache.insert("huge", for: "b", cost: 101))
        #expect(cache.usage.bytes == 10)
    }

    @Test func evictionOrderIsSpeculativeThenRecentThenRetained() {
        let cache = memoryCache(limit: 40)
        cache.insert("a", for: "retained", cost: 10, tier: .retained)
        cache.insert("b", for: "recent-old", cost: 10, tier: .recent)
        cache.insert("c", for: "speculative", cost: 10, tier: .speculative)
        cache.insert("d", for: "recent-new", cost: 10, tier: .recent)

        cache.setLimits(CacheLimits(bytes: 30, speculativeBytes: 30))
        #expect(!cache.contains("speculative"), "speculative goes first, though it is newer than recent-old")
        cache.setLimits(CacheLimits(bytes: 20, speculativeBytes: 20))
        #expect(!cache.contains("recent-old"), "then the least recently used recent")
        #expect(cache.contains("recent-new"))
        cache.setLimits(CacheLimits(bytes: 10, speculativeBytes: 10))
        #expect(!cache.contains("recent-new"))
        #expect(cache.contains("retained"), "retained goes last")
        cache.setLimits(CacheLimits(bytes: 0, speculativeBytes: 0))
        #expect(!cache.contains("retained"))
        #expect(cache.statistics.evictions == 4)
    }

    @Test func lruOrderWithinATierFollowsUse() {
        let cache = memoryCache(limit: 30)
        cache.insert("a", for: "a", cost: 10)
        cache.insert("b", for: "b", cost: 10)
        cache.insert("c", for: "c", cost: 10)
        #expect(cache.value(for: "a") == "a")
        #expect(cache.orderedKeys(in: .recent) == ["b", "c", "a"])
        cache.insert("d", for: "d", cost: 10)
        #expect(!cache.contains("b"), "b is now the least recently used")
        #expect(cache.contains("a"))
    }

    @Test func peekNeitherTouchesNorPromotes() {
        let cache = memoryCache(limit: 30)
        cache.insert("a", for: "a", cost: 10, tier: .speculative)
        cache.insert("b", for: "b", cost: 10, tier: .speculative)
        #expect(cache.peek("a") == "a")
        #expect(cache.tier(of: "a") == .speculative)
        #expect(cache.orderedKeys(in: .speculative) == ["a", "b"])
        #expect(cache.statistics.hits == 0)
    }

    @Test func firstUsePromotesSpeculativeToRecent() {
        let cache = memoryCache(limit: 30)
        cache.insert("a", for: "a", cost: 10, tier: .speculative)
        #expect(cache.value(for: "a") == "a")
        #expect(cache.tier(of: "a") == .recent)
        #expect(cache.usage.bytesByTier == [.recent: 10])
    }

    @Test func reinsertingKeepsTheHigherTier() {
        let cache = memoryCache(limit: 30)
        cache.insert("a", for: "a", cost: 10, tier: .retained)
        cache.insert("a2", for: "a", cost: 12, tier: .speculative)
        #expect(cache.tier(of: "a") == .retained, "a prefetch never demotes what was seen")
        #expect(cache.peek("a") == "a2")
        #expect(cache.usage.bytes == 12)
    }

    @Test func theEntryBeingStoredIsNeverItsOwnVictim() {
        let cache = memoryCache(limit: 30)
        cache.insert("a", for: "a", cost: 10)
        cache.insert("b", for: "b", cost: 10)
        cache.insert("c", for: "c", cost: 10)
        #expect(cache.insert("p", for: "prefetched", cost: 10, tier: .speculative))
        #expect(cache.contains("prefetched"), "a prefetch into a full cache displaces old recent entries")
        #expect(!cache.contains("a"))
    }

    @Test func aSpeculativeInsertNeverDisplacesRetained() {
        let cache = memoryCache(limit: 20)
        cache.insert("a", for: "a", cost: 10, tier: .retained)
        cache.insert("b", for: "b", cost: 10, tier: .retained)
        #expect(!cache.insert("p", for: "p", cost: 10, tier: .speculative))
        #expect(cache.contains("a") && cache.contains("b"))
        #expect(cache.insert("r", for: "r", cost: 10, tier: .recent), "a recent insert may displace retained")
        #expect(!cache.contains("a"))
    }

    @Test func speculativeBytesHaveTheirOwnCap() {
        let cache = memoryCache(limit: 100, speculativeLimit: 20)
        cache.insert("seen", for: "seen", cost: 50)
        cache.insert("1", for: "s1", cost: 10, tier: .speculative)
        cache.insert("2", for: "s2", cost: 10, tier: .speculative)
        cache.insert("3", for: "s3", cost: 10, tier: .speculative)
        #expect(!cache.contains("s1"), "the oldest prefetch makes room under the speculative cap")
        #expect(cache.contains("s2") && cache.contains("s3") && cache.contains("seen"))
        #expect(cache.usage.bytesByTier[.speculative] == 20)
        #expect(!cache.insert("big", for: "big", cost: 21, tier: .speculative))
    }

    @Test func aLeasedEntrySurvivesEveryTrimAndAnyBudget() throws {
        let cache = memoryCache(limit: 100)
        cache.insert("pinned", for: "pinned", cost: 10, tier: .speculative)
        cache.insert("other", for: "other", cost: 10, tier: .retained)
        let lease = try #require(cache.lease("pinned"))
        #expect(cache.tier(of: "pinned") == .recent, "a lease is a use: promoted")
        for depth in TrimDepth.allCases {
            cache.trim(depth)
            #expect(cache.contains("pinned"), "survives \(depth)")
        }
        #expect(!cache.contains("other"))
        cache.setLimits(CacheLimits(bytes: 0, speculativeBytes: 0))
        #expect(cache.contains("pinned"))
        #expect(cache.usage.pinnedBytes == 10)
        lease.release()
    }

    @Test func releasingTheLastLeaseMakesTheEntryEvictableAgain() throws {
        let cache = memoryCache(limit: 100)
        cache.insert("a", for: "a", cost: 10)
        let first = try #require(cache.lease("a"))
        let second = try #require(cache.lease("a"))
        cache.setLimits(CacheLimits(bytes: 5, speculativeBytes: 5))
        first.release()
        first.release()
        #expect(cache.contains("a"), "a double release does not drop the other lease")
        #expect(cache.isLeased("a"))
        second.release()
        #expect(!cache.contains("a"), "over budget once unleased")
    }

    @Test func aDeallocatedLeaseReleasesItself() {
        let cache = memoryCache(limit: 100)
        cache.insert("a", for: "a", cost: 10)
        do {
            let lease = cache.lease("a")
            #expect(lease != nil)
            #expect(cache.isLeased("a"))
        }
        #expect(!cache.isLeased("a"))
    }

    @Test func insertLeasedIsNeverRefused() {
        let cache = memoryCache(limit: 10)
        let lease = cache.insertLeased("big", for: "big", cost: 50, tier: .speculative)
        #expect(cache.contains("big"))
        #expect(cache.tier(of: "big") == .recent)
        lease.release()
        #expect(!cache.contains("big"))
    }

    @Test func aSpeculativeEntryExpiresAfter24Hours() {
        let clock = ManualCacheClock()
        let cache = memoryCache(limit: 100, clock: clock)
        cache.insert("p", for: "p", cost: 10, tier: .speculative)
        clock.advance(by: CacheTier.speculativeLifetime - 1)
        #expect(cache.peek("p") == "p")
        clock.advance(by: 2)
        #expect(cache.peek("p") == nil)
        #expect(cache.value(for: "p") == nil)
        #expect(cache.statistics.expirations == 1)
        #expect(cache.usage.bytes == 0)
    }

    @Test func aPromotedSpeculativeEntryNeverExpires() {
        let clock = ManualCacheClock()
        let cache = memoryCache(limit: 100, clock: clock)
        cache.insert("p", for: "p", cost: 10, tier: .speculative)
        _ = cache.value(for: "p")
        clock.advance(by: 2 * CacheTier.speculativeLifetime)
        #expect(cache.value(for: "p") == "p")
    }

    @Test func expiredEntriesGoOnAnyTrim() {
        let clock = ManualCacheClock()
        let cache = memoryCache(limit: 100, clock: clock)
        cache.insert("p", for: "p", cost: 10, tier: .speculative)
        cache.insert("signed", for: "signed", cost: 10, tier: .retained, expiresAt: clock.now.addingTimeInterval(60))
        cache.insert("kept", for: "kept", cost: 10, tier: .retained)
        clock.advance(by: CacheTier.speculativeLifetime + 1)
        cache.trim(.expired)
        #expect(cache.usage.count == 1)
        #expect(cache.contains("kept"))
        #expect(cache.statistics.expirations == 2)
    }

    @Test func trimDepthsCutWhatTheySay() {
        let cache = memoryCache(limit: 100)
        cache.insert("s", for: "s", cost: 10, tier: .speculative)
        for index in 1...4 { cache.insert("r\(index)", for: "r\(index)", cost: 10) }
        cache.insert("t", for: "t", cost: 10, tier: .retained)

        cache.trim(.speculative)
        #expect(!cache.contains("s"))
        #expect(cache.usage.count == 5)

        cache.trim(.speculativeAndHalfRecent)
        #expect(!cache.contains("r1") && !cache.contains("r2"), "the least recent half of recent")
        #expect(cache.contains("r3") && cache.contains("r4") && cache.contains("t"))

        cache.trim(.belowRetained)
        #expect(cache.orderedKeys(in: .recent).isEmpty)
        #expect(cache.contains("t"))

        cache.trim(.allButPinned)
        #expect(cache.usage.count == 0)
    }

    @Test func aWipeHidesLeasedEntriesAndAStaleLeaseIsANoOp() throws {
        let cache = memoryCache(limit: 100)
        cache.insert("old", for: "a", cost: 10)
        let stale = try #require(cache.lease("a"))
        cache.removeAll()
        #expect(cache.peek("a") == nil, "never served to the next viewer")
        #expect(cache.usage == CacheUsage(byteLimit: 100))
        cache.insert("new", for: "a", cost: 10)
        stale.release()
        #expect(cache.peek("a") == "new")
        #expect(!cache.isLeased("a"))
    }

    @Test func setTierMovesAnEntryBetweenLists() {
        let clock = ManualCacheClock()
        let cache = memoryCache(limit: 100, clock: clock)
        cache.insert("a", for: "a", cost: 10)
        cache.setTier(.retained, for: "a")
        #expect(cache.orderedKeys(in: .retained) == ["a"])
        cache.setTier(.speculative, for: "a")
        clock.advance(by: CacheTier.speculativeLifetime + 1)
        #expect(cache.peek("a") == nil, "demoted to speculative: its 24 h started")
    }

    @Test func usageReportsTiersAndPins() {
        let cache = memoryCache(limit: 100)
        cache.insert("s", for: "s", cost: 5, tier: .speculative)
        cache.insert("r", for: "r", cost: 7)
        cache.insert("t", for: "t", cost: 11, tier: .retained)
        let lease = cache.lease("t")
        let usage = cache.usage
        #expect(usage.bytes == 23)
        #expect(usage.count == 3)
        #expect(usage.pinnedBytes == 11)
        #expect(usage.bytesByTier == [.speculative: 5, .recent: 7])
        lease?.release()
        #expect(cache.usage.bytesByTier == [.speculative: 5, .recent: 7, .retained: 11])
    }

    /// An evicted value is released after the lock: one whose deinit ends a
    /// lease on the same cache would otherwise re-enter the lock and trap.
    @Test func aValueEndingALeaseInItsDeinitIsReleasedOutsideTheLock() throws {
        final class LeaseHolder: Sendable {
            let lease: CacheLease?
            init(_ lease: CacheLease?) { self.lease = lease }
            deinit { lease?.release() }
        }
        let cache = MemoryCache<String, LeaseHolder>(namespace: namespace("holders"), budget: .fixed(bytes: 100), limits: CacheLimits(bytes: 100, speculativeBytes: 100))
        cache.insert(LeaseHolder(nil), for: "art", cost: 1)
        let firstLease: CacheLease = try #require(cache.lease("art"))
        cache.insert(LeaseHolder(firstLease), for: "tile", cost: 1)
        #expect(cache.isLeased("art"))
        // The trim evicts the tile; its deinit ends the lease on the art.
        cache.trim(.belowRetained)
        #expect(!cache.contains("tile"))
        #expect(!cache.isLeased("art"), "the tile's deinit ended the lease")
        #expect(cache.contains("art"), "leased during the pass, so the trim kept it")
        // Same through a budget eviction and a wipe.
        let secondLease: CacheLease = try #require(cache.lease("art"))
        cache.insert(LeaseHolder(secondLease), for: "tile", cost: 1)
        cache.setLimits(CacheLimits(bytes: 0, speculativeBytes: 0))
        #expect(!cache.isLeased("art"))
        cache.insert(LeaseHolder(nil), for: "art", cost: 1)
        cache.removeAll()
        #expect(cache.usage.count == 0)
    }

    /// The synchronous surface under contention from many threads at once,
    /// the shape that crashed the actor-based ImagePipeline.
    @Test func concurrentUseKeepsTheBookkeepingConsistent() async {
        let cache = MemoryCache<Int, Int>(
            namespace: namespace("stress"),
            budget: .fixed(bytes: 500),
            limits: CacheLimits(bytes: 500, speculativeBytes: 100)
        )
        await withTaskGroup(of: Void.self) { group in
            for worker in 0..<8 {
                group.addTask {
                    for step in 0..<400 {
                        let key = (worker * 31 + step) % 97
                        let tier = CacheTier.allCases[step % 3]
                        cache.insert(step, for: key, cost: 1 + step % 9, tier: tier)
                        _ = cache.value(for: (key + 3) % 97)
                        if let lease = cache.lease((key + 7) % 97), step % 2 == 0 { lease.release() }
                        if step % 50 == 0 { cache.trim(.speculativeAndHalfRecent) }
                    }
                }
            }
        }
        let usage = cache.usage
        #expect(usage.pinnedBytes == 0, "every lease was released")
        #expect(usage.bytes <= 500)
        #expect(usage.bytes == usage.bytesByTier.values.reduce(0, +))
        #expect((usage.bytesByTier[.speculative] ?? 0) <= 100)
    }
}

struct LRUListTests {
    @Test func appendRemoveTouchKeepOrder() {
        var list = LRUList<String>()
        for key in ["a", "b", "c", "d"] { list.append(key) }
        list.touch("b")
        list.remove("c")
        #expect(list.ordered == ["a", "d", "b"])
        #expect(list.first == "a" && list.last == "b")
        list.append("a")
        #expect(list.ordered == ["d", "b", "a"])
        #expect(list.key(after: "d") == "b")
        list.removeAll()
        #expect(list.isEmpty && list.first == nil && list.last == nil)
    }

    @Test func victimSkipsTheExcludedKeyAndRespectsTheCeiling() {
        var lru = TieredLRU<String>()
        lru.append("r1", tier: .recent)
        lru.append("s1", tier: .speculative)
        lru.append("t1", tier: .retained)
        #expect(lru.victim() == "s1")
        #expect(lru.victim(excluding: "s1") == "r1")
        lru.remove("r1", tier: .recent)
        #expect(lru.victim(upTo: .recent, excluding: "s1") == nil)
        #expect(lru.victim(upTo: .retained, excluding: "s1") == "t1")
    }
}
