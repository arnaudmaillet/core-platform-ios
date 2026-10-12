import Foundation
import Synchronization
import Testing
@testable import CacheKit

/// The `-cache-audit` counters (#900): evictions per reason through the
/// coordinator, the fates of speculative entries, the lookahead's counters,
/// and the log the instrument writes.
final class CacheAuditTests {
    private let folder = TemporaryFolder()
    private let clock = ManualCacheClock()
    private let fake = FakeDevice()

    private func makeCoordinator(limit: CacheStorageLimit = .automatic, conditions: CacheConditions = CacheConditions()) -> CacheCoordinator {
        CacheCoordinator(device: fake.device, storageLimit: limit, conditions: conditions)
    }

    private func memory(_ name: String, bytes: Int = 1_000, scope: CacheScope = .public, category: CacheCategory = .images, priorityClass: CachePriorityClass = .standard) -> MemoryCache<String, String> {
        MemoryCache(namespace: namespace(name, category, scope: scope, priorityClass: priorityClass), budget: .fixed(bytes: bytes), clock: clock)
    }

    private func disk(_ name: String, _ budget: DiskBudget = DiskBudget(pool: .images), scope: CacheScope = .public, category: CacheCategory = .images) throws -> DiskStore {
        try DiskStore(namespace: namespace(name, category, scope: scope), budget: budget, root: folder.url, clock: clock)
    }

    /// The conservation every cache keeps: each speculative byte stored is
    /// used, wasted, discarded, or still held.
    private func balances(_ statistics: CacheStatistics, _ usage: CacheUsage) -> Bool {
        let fates = statistics.speculative
        let held = usage.bytesByTier[.speculative, default: 0]
        return fates.storedBytes == fates.usedBytes + fates.wastedBytes + fates.discardedBytes + held
    }

    // MARK: - Evictions per reason

    @Test func everyCoordinatorSignalCountsItsEvictionsUnderItsOwnReason() throws {
        // 9 MB split 3:5:1: the images pool holds 3 MB.
        let coordinator = makeCoordinator(limit: .total(bytes: 9 * megabyte))
        let feed = memory("feed")
        let viewer = memory("viewer", scope: .viewer, category: .other)
        let images = try disk("images")
        for cache in [feed, viewer, images] as [any ManagedCache] { coordinator.register(cache) }

        feed.insert("a", for: "spec", cost: 10, tier: .speculative)
        coordinator.trim(.memoryWarning)
        #expect(feed.statistics.removals[.memoryWarning] == 1)
        #expect(feed.statistics.removedBytes[.memoryWarning] == 10)

        feed.insert("b", for: "recent", cost: 10)
        coordinator.trim(.background)
        #expect(feed.statistics.removals[.background] == 1)

        feed.insert("c", for: "retained", cost: 10, tier: .retained)
        coordinator.trim(.memoryCritical)
        #expect(feed.statistics.removals[.memoryCritical] == 1)

        try images.write(bytes(2 * megabyte), for: "big")
        fake.setFreeDisk(2 * Int64(CacheBytes.gigabyte))
        coordinator.refreshDiskSpace()
        #expect(images.statistics.removals[.lowDisk] == 1, "low disk halves the pool to 1.5 MB, which evicts it")
        #expect(images.statistics.removedBytes[.lowDisk] == 2 * megabyte)

        viewer.insert("v", for: "v", cost: 5)
        feed.insert("kept", for: "kept", cost: 5)
        coordinator.trim(.viewerChanged)
        #expect(viewer.statistics.removals[.viewerChanged] == 1)
        #expect(feed.statistics.removals[.viewerChanged] == nil, "public media survive a viewer change")

        try images.write(bytes(10), for: "small")
        coordinator.trim(.clear(.images))
        #expect(feed.statistics.removals[.clear] == 1)
        #expect(images.statistics.removals[.clear] == 1)

        // A wipe is not an eviction; the legacy counters stay what they were.
        #expect(feed.statistics.evictions == 3)
        #expect(images.statistics.evictions == 1)
        DiskStore.drainJanitor()
    }

    @Test func budgetAndExpiryAreCountedApart() throws {
        let cache = memoryCache(limit: 20)
        cache.insert("a", for: "a", cost: 10)
        cache.insert("b", for: "b", cost: 10)
        cache.insert("c", for: "c", cost: 10)
        #expect(cache.statistics.removals[.budget] == 1)

        let clock = ManualCacheClock()
        let expiring = memoryCache(limit: 100, clock: clock)
        expiring.insert("s", for: "s", cost: 10, tier: .speculative)
        clock.advance(by: CacheTier.speculativeLifetime + 1)
        #expect(expiring.value(for: "s") == nil)
        #expect(expiring.statistics.removals[.expiry] == 1)
        #expect(expiring.statistics.expirations == 1)
        #expect(expiring.statistics.speculative.wasted == 1, "an unused prefetch that expired was wasted")
    }

    @Test func aTrimWithoutAReasonCountsAsTrimAndAWipeAsWipe() {
        let cache = memoryCache(limit: 100)
        cache.insert("a", for: "a", cost: 10, tier: .speculative)
        cache.trim(.speculative)
        #expect(cache.statistics.removals[.trim] == 1)
        cache.insert("b", for: "b", cost: 10)
        cache.removeAll()
        #expect(cache.statistics.removals[.wipe] == 1)
        #expect(cache.statistics.evictions == 1)
    }

    // MARK: - Speculative fates

    @Test func speculativeEntriesAreUsedWastedOrDiscardedAndAlwaysBalance() {
        let cache = memoryCache(limit: 100, speculativeLimit: 30)
        cache.insert("a", for: "used-by-read", cost: 10, tier: .speculative)
        cache.insert("b", for: "used-by-lease", cost: 10, tier: .speculative)
        cache.insert("c", for: "used-by-store", cost: 10, tier: .speculative)
        #expect(cache.statistics.speculative.stored == 3)
        #expect(balances(cache.statistics, cache.usage))

        _ = cache.value(for: "used-by-read")
        let lease = cache.lease("used-by-lease")
        cache.insert("C", for: "used-by-store", cost: 12, tier: .recent)
        #expect(cache.statistics.speculative.used == 3)
        #expect(cache.statistics.speculative.usedBytes == 30)
        #expect(balances(cache.statistics, cache.usage))

        cache.insert("d", for: "replaced", cost: 10, tier: .speculative)
        cache.insert("D", for: "replaced", cost: 8, tier: .speculative)
        #expect(cache.statistics.speculative.discarded == 1, "a prefetch replaced by another is neither used nor wasted")
        #expect(balances(cache.statistics, cache.usage))

        for index in 0..<4 { cache.insert("e", for: "over-cap-\(index)", cost: 10, tier: .speculative) }
        #expect(cache.statistics.speculative.wasted >= 2, "the speculative cap evicted unused prefetches")
        #expect(balances(cache.statistics, cache.usage))

        cache.insert("f", for: "removed", cost: 1, tier: .speculative)
        cache.removeValue(for: "removed")
        cache.removeAll()
        #expect(balances(cache.statistics, cache.usage))
        #expect(cache.usage.bytesByTier[.speculative, default: 0] == 0)
        let fates = cache.statistics.speculative
        #expect(fates.wasteRatio == Double(fates.wastedBytes) / Double(fates.usedBytes + fates.wastedBytes))
        lease?.release()
    }

    @Test func aRefusedSpeculativeStoreIsNeverCountedAsStored() {
        let cache = memoryCache(limit: 100, speculativeLimit: 10)
        #expect(!cache.insert("big", for: "big", cost: 11, tier: .speculative))
        #expect(cache.statistics.speculative.stored == 0)
        #expect(balances(cache.statistics, cache.usage))
    }

    @Test func aDiskStoreBalancesItsSpeculativeBytesToo() throws {
        let store = try disk("spec")
        store.setLimits(CacheLimits(bytes: 1_000, speculativeBytes: 300))
        try store.write(bytes(100), for: "read", tier: .speculative)
        try store.write(bytes(100), for: "leased", tier: .speculative)
        try store.write(bytes(100), for: "rewritten", tier: .speculative)
        #expect(store.data(for: "read") != nil)
        let lease = store.lease("leased")
        try store.write(bytes(120), for: "rewritten", tier: .recent)
        #expect(store.statistics.speculative.used == 3)
        try store.write(bytes(200), for: "evicts", tier: .speculative)
        try store.write(bytes(200), for: "evicts-too", tier: .speculative)
        #expect(store.statistics.speculative.wasted == 1)
        #expect(store.statistics.removals[.budget] == 1)
        #expect(balances(store.statistics, store.usage))

        clock.advance(by: CacheTier.speculativeLifetime + 1)
        store.trim(.expired, reason: .background)
        #expect(store.statistics.removals[.expiry] == 1)
        #expect(store.statistics.speculative.wasted == 2)
        #expect(balances(store.statistics, store.usage))
        lease?.release()
        store.removeAll(reason: .clear)
        #expect(balances(store.statistics, store.usage))
        DiskStore.drainJanitor()
    }

    @Test func aReopenedStoreCountsWhatItRecoveredAsStored() throws {
        do {
            let store = try disk("reopen")
            try store.write(bytes(50), for: "s", tier: .speculative)
            store.flush()
        }
        let reopened = try disk("reopen")
        #expect(reopened.statistics.speculative.storedBytes == 50)
        #expect(balances(reopened.statistics, reopened.usage))
    }

    // MARK: - Coordinator report

    @Test func theUsageReportCarriesEveryCachesStatisticsAndTheAppsWasteRatio() throws {
        let coordinator = makeCoordinator()
        let feed = memory("feed")
        let video = try disk("video", DiskBudget(pool: .video), category: .videos)
        coordinator.register(feed)
        coordinator.register(video)
        feed.insert("a", for: "a", cost: 10, tier: .speculative)
        feed.insert("b", for: "b", cost: 30, tier: .speculative)
        _ = feed.value(for: "a")
        try video.write(bytes(10), for: "v", tier: .speculative)
        coordinator.trim(.memoryWarning)

        let report = coordinator.usage()
        #expect(report.lines.first { $0.namespace.name == "feed" }?.statistics == feed.statistics)
        let all = report.speculative()
        #expect(all.usedBytes == 10)
        #expect(all.wastedBytes == 30)
        #expect(all.wasteRatio == 0.75)
        #expect(report.speculative(in: .videos).storedBytes == 10)
    }

    @Test func trimObserversHearEveryTrimWithItsReason() {
        let coordinator = makeCoordinator()
        let heard = Mutex<[TrimReason]>([])
        let observation = coordinator.observeTrims { reason in heard.withLock { $0.append(reason) } }
        coordinator.trim(.memoryWarning)
        coordinator.handle(.viewerChanged)
        coordinator.trim(.clear(nil))
        #expect(heard.withLock { $0 } == [.memoryWarning, .viewerChanged, .clear(nil)])

        observation.cancel()
        coordinator.trim(.background)
        #expect(heard.withLock { $0.count } == 3)
    }

    // MARK: - Prefetch counters

    @Test func prefetchCountersReportHitRateFirstRangeAndTimeToFirstFrame() {
        let counters = CachePrefetchCounters()
        for _ in 0..<6 { counters.recordArrival(.images, .ready) }
        counters.recordArrival(.images, .inFlight)
        counters.recordArrival(.images, .missed)
        counters.recordNextVideoStart(firstRangeHit: true)
        counters.recordNextVideoStart(firstRangeHit: true)
        counters.recordNextVideoStart(firstRangeHit: false)
        for milliseconds in [100.0, 200, 300, 400, 1_000] { counters.recordTimeToFirstFrame(milliseconds / 1_000) }
        counters.recordTimeToFirstFrame(.nan)

        let snapshot = counters.snapshot
        #expect(snapshot.arrivals[.images]?.hitRate == 0.75)
        #expect(snapshot.arrivals[.videos] == nil)
        #expect(snapshot.nextVideoFirstRangeHitRate == 2.0 / 3.0)
        #expect(snapshot.firstFrame.count == 5)
        #expect(snapshot.firstFrame.percentile(0.5) == 0.3)
        #expect(snapshot.firstFrame.percentile(0.9) == 1.0)
        #expect(snapshot.firstFrame.maximum == 1.0)

        counters.reset()
        #expect(counters.snapshot == CachePrefetchCounters.Snapshot())
    }

    @Test func theFirstFrameWindowKeepsOnlyTheRecentSamples() {
        let counters = CachePrefetchCounters()
        for index in 0..<(CachePrefetchCounters.firstFrameWindow + 10) { counters.recordTimeToFirstFrame(Double(index)) }
        let frames = counters.snapshot.firstFrame
        #expect(frames.count == CachePrefetchCounters.firstFrameWindow + 10)
        #expect(frames.recent.count == CachePrefetchCounters.firstFrameWindow)
        #expect(frames.recent.first == 10)
    }

    @Test func transfersOnACellularOrExpensivePathCountAsCellular() {
        let coordinator = makeCoordinator()
        coordinator.recordTransfer(bytes: 100, priority: .speculative)
        coordinator.handle(.network(.cellular, isConstrained: false, isExpensive: true))
        coordinator.recordTransfer(bytes: 40, priority: .speculative)
        coordinator.recordTransfer(bytes: 7, priority: .visible)
        coordinator.handle(.network(.wifi, isConstrained: false, isExpensive: true))
        coordinator.recordTransfer(bytes: 2, priority: .speculative)

        let snapshot = coordinator.prefetchCounters.snapshot
        #expect(snapshot.speculativeCellularBytes == 42, "a personal hotspot is expensive like cellular")
        #expect(snapshot.otherBytes[.speculative] == 100)
        #expect(snapshot.cellularBytes[.visible] == 7)
    }

    // MARK: - The log

    @Test func theLogHasAHeaderALinePerNamespaceAndThePrefetchLine() throws {
        let coordinator = makeCoordinator()
        let feed = memory("images.decoded", bytes: 100 * megabyte)
        let video = try disk("video", DiskBudget(pool: .video), category: .videos)
        coordinator.register(feed)
        coordinator.register(video)
        feed.insert("a", for: "a", cost: 2 * megabyte, tier: .speculative)
        feed.insert("b", for: "b", cost: 3 * megabyte, tier: .retained)
        _ = feed.value(for: "b")
        _ = feed.value(for: "missing")
        coordinator.trim(.memoryWarning)
        coordinator.prefetchCounters.recordArrival(.images, .ready)
        coordinator.prefetchCounters.recordNextVideoStart(firstRangeHit: true)

        let lines = CacheAudit.lines(
            trigger: "trim:memoryWarning",
            uptime: 12.34,
            report: coordinator.usage(),
            prefetch: coordinator.prefetchCounters.snapshot,
            limit: coordinator.storageLimit,
            pressure: coordinator.diskPressure,
            conditions: coordinator.conditions
        )
        #expect(lines.count == 4)
        #expect(lines.allSatisfy { $0.hasPrefix(CacheAudit.prefix) })
        #expect(lines[0].contains("t=12.3 trigger=trim:memoryWarning limit=automatic diskPressure=normal policy=full network=wifi"))
        #expect(lines[0].contains("waste=100%(2.0MB of 2.0MB)"))
        let decoded = try #require(lines.first { $0.contains("ns=images.decoded ") })
        #expect(decoded.contains("medium=memory class=standard scope=public"))
        #expect(decoded.contains("bytes=3.0MB/100.0MB(3%)"))
        #expect(decoded.contains("hits=1 misses=1 hitRate=50%"))
        #expect(decoded.contains("removed=memoryWarning:1/2.0MB"))
        #expect(decoded.contains("speculative=stored:1/2.0MB,used:0/0.0MB,wasted:1/2.0MB,discarded:0/0.0MB waste=100%"))
        #expect(lines.contains { $0.contains("ns=video medium=disk") && $0.contains("bytes=0.0MB/500.0MB(0%)") })
        let prefetch = try #require(lines.last)
        #expect(prefetch.contains("prefetch images=ready:1,inFlight:0,missed:0,hitRate:100%"))
        #expect(prefetch.contains("nextVideoFirstRange=1/1(100%)"))
        #expect(prefetch.contains("timeToFirstFrame=n:0,p50:-,p90:-,max:-"))
        #expect(prefetch.contains("fetched=P0:0.0MB,P1:0.0MB,P2:0.0MB p2Cellular=0.0MB"))

        let lessCellular = CacheAudit.lines(
            trigger: "interval",
            uptime: 0,
            report: coordinator.usage(),
            prefetch: coordinator.prefetchCounters.snapshot,
            limit: .oneGigabyte,
            pressure: .low,
            conditions: CacheConditions(network: .cellular, usesLessCellularData: true)
        )
        #expect(lessCellular[0].contains("limit=1000.0MB diskPressure=low policy=reduced network=cellular(lessCellularData)"))
    }

    @Test func theAuditLogsAtStartAndAfterEachTrim() async {
        let coordinator = makeCoordinator()
        coordinator.register(memory("feed"))
        let blocks = Mutex<[[String]]>([])
        let audit = CacheAudit(coordinator: coordinator, interval: 3_600, uptime: { 1 }) { lines in
            blocks.withLock { $0.append(lines) }
        }
        audit.start()
        #expect(await eventually { blocks.withLock { $0.count } == 1 })
        coordinator.trim(.lowDisk(.low))
        #expect(await eventually { blocks.withLock { $0.count } == 2 })
        let triggers = blocks.withLock { $0.map { $0[0] } }
        #expect(triggers[0].contains("trigger=start"))
        #expect(triggers[1].contains("trigger=trim:lowDisk(low)"))
        #expect(triggers[1].contains("diskPressure=low"))

        audit.stop()
        coordinator.trim(.memoryWarning)
        try? await Task.sleep(for: .milliseconds(100))
        #expect(blocks.withLock { $0.count } == 2, "a stopped audit logs nothing more")
    }

    @Test func theAuditStartsOnlyWhenTheLaunchArgumentAsksForIt() {
        let coordinator = makeCoordinator()
        #expect(CacheAudit.startIfRequested(coordinator, arguments: ["app", "-media-audit"]) == nil)
    }
}
