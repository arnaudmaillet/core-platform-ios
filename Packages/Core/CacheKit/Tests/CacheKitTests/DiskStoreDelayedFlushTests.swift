import Foundation
import Synchronization
import Testing
@testable import CacheKit

/// The disk index is written a few seconds after the last change, not only
/// every `flushThreshold` changes and on background (#1079): a foreground
/// kill loses seconds of changes, a burst is one write. Time is the test's
/// `ManualCacheClock`, and the delayed flush runs when the test steps the
/// `ManualFlushScheduler`: nothing here waits on the wall clock.
final class DiskStoreDelayedFlushTests {
    private let folder = TemporaryFolder()
    private let clock = ManualCacheClock()
    private let scheduler = ManualFlushScheduler()

    private func open(limit: Int = 1_000) throws -> DiskStore {
        try DiskStore(
            namespace: namespace("media"),
            budget: DiskBudget(pool: .images),
            root: folder.url,
            limits: CacheLimits(bytes: limit, speculativeBytes: limit),
            clock: clock,
            flushDelay: 3,
            flushMaxDelay: 10,
            flushScheduler: scheduler
        )
    }

    /// The keys the index ON DISK names.
    private func indexedKeys() -> Set<String> {
        let url = folder.url.appending(path: "media/v1/index.json")
        guard let data = try? Data(contentsOf: url),
              let index = try? JSONDecoder().decode(DiskStore.IndexFile.self, from: data) else { return [] }
        return Set(index.records.map(\.key))
    }

    @Test func aSingleChangeIsOnDiskWithinTheDelay() throws {
        let store = try open()
        try store.write(bytes(10), for: "a")
        #expect(store.statistics.indexWrites == 0, "no 32-change or background trigger")
        #expect(indexedKeys().isEmpty)
        #expect(scheduler.pendingDelays == [3], "one flush armed, the delay away")

        clock.advance(by: 2.9)
        scheduler.runPending()
        #expect(indexedKeys().isEmpty, "not before the delay")
        #expect(scheduler.pendingDelays.count == 1, "re-armed for what is left")

        clock.advance(by: 0.1)
        scheduler.runPending()
        #expect(indexedKeys() == ["a"], "on disk once the delay passed")
        #expect(store.statistics.indexWrites == 1)
        #expect(store.statistics.delayedIndexWrites == 1, "the delayed flush wrote it")
        #expect(scheduler.pendingDelays.isEmpty, "nothing armed once written")
    }

    @Test func aBurstInsideTheDelayIsOneIndexWrite() throws {
        let store = try open()
        for index in 0..<20 {
            try store.write(bytes(10), for: "key-\(index)")
            _ = store.data(for: "key-\(index)")
            clock.advance(by: 0.1)
        }
        #expect(scheduler.pendingDelays.count == 1, "one flush armed for the whole burst")

        // Steps until nothing is armed: the flush waits for the burst's end.
        clock.advance(by: 3)
        scheduler.runUntilIdle()
        #expect(store.statistics.indexWrites == 1, "one write for the burst")
        #expect(indexedKeys().count == 20)
    }

    /// A store that never goes quiet (a long scroll) still writes a change
    /// to its files within `flushMaxDelay`.
    @Test func aStoreThatNeverGoesQuietWritesWithinTheLongestDelay() throws {
        let store = try open()
        try store.write(bytes(10), for: "first")
        for second in 1...12 {
            clock.advance(by: 1)
            try store.write(bytes(10), for: "later-\(second)")
            scheduler.runPending()
            if second < 10 {
                #expect(store.statistics.indexWrites == 0, "still inside the longest delay at \(second)s")
            }
        }
        #expect(store.statistics.indexWrites == 1, "written at the longest delay, while busy")
        #expect(indexedKeys().contains("first"))
    }

    /// A use alone (access times) waits for a pause, however long: a scroll's
    /// reads never turn into periodic index writes.
    @Test func usesAloneWaitForAPause() throws {
        let store = try open()
        try store.write(bytes(10), for: "a")
        clock.advance(by: 3)
        scheduler.runUntilIdle()
        #expect(store.statistics.indexWrites == 1)

        for _ in 0..<30 {
            clock.advance(by: 1)
            _ = store.data(for: "a")
            scheduler.runPending()
        }
        #expect(store.statistics.indexWrites == 1, "30 s of reads with no pause: no write")
        clock.advance(by: 3)
        scheduler.runUntilIdle()
        #expect(store.statistics.indexWrites == 2, "written once they pause")
    }

    /// The wall clock set back an hour (the user changed the time) does not
    /// hold the write back an hour.
    @Test func aClockSetBackDoesNotHoldTheWriteBack() throws {
        let store = try open()
        try store.write(bytes(10), for: "a")
        clock.advance(by: -3_600)
        scheduler.runPending()
        #expect(store.statistics.indexWrites == 1)
        #expect(indexedKeys() == ["a"])
    }

    /// A write the threshold or the background already made leaves the armed
    /// flush nothing to do.
    @Test func anArmedFlushAfterAnExplicitFlushWritesNothing() throws {
        let store = try open()
        try store.write(bytes(10), for: "a")
        store.flush()
        #expect(store.statistics.indexWrites == 1)
        clock.advance(by: 3)
        scheduler.runUntilIdle()
        #expect(store.statistics.indexWrites == 1)
        #expect(store.statistics.delayedIndexWrites == 0)
        #expect(scheduler.pendingDelays.isEmpty)
    }

    /// In the app the delayed flush runs on the store's own utility queue,
    /// never the main thread, and writes the index with nobody stepping it.
    @MainActor @Test func theDelayedFlushRunsOnTheStoresOwnQueueOffMain() async throws {
        let store = try DiskStore(
            namespace: namespace("own-queue"), budget: DiskBudget(pool: .images), root: folder.url,
            clock: clock, flushDelay: 0
        )
        let scheduler = try #require(store.flushScheduler as? DispatchFlushScheduler)
        #expect(scheduler.queue.label == "CacheKit.DiskStore.flush.own-queue")
        #expect(scheduler.queue.qos.qosClass == .utility)
        #expect(scheduler.queue !== DispatchQueue.main)

        final class Probe: Sendable {
            let ranOnMain = Mutex<Bool?>(nil)
        }
        let probe = Probe()
        scheduler.schedule(after: 0) { probe.ranOnMain.withLock { $0 = Thread.isMainThread } }
        try store.write(bytes(10), for: "a")
        #expect(await eventually { store.statistics.indexWrites == 1 }, "written with nobody stepping it")
        #expect(await eventually { probe.ranOnMain.withLock { $0 } != nil })
        #expect(probe.ranOnMain.withLock { $0 } == false)
    }

    enum MutationPath: String, CaseIterable, CustomTestStringConvertible {
        case write, moveItem, read, fileURL, lease, leaseEndEviction, setTier, removeValue, removeAll
        case setLimitsEviction, trim, expiry, vanishedFile

        var testDescription: String { rawValue }
    }

    /// Every path that changes the index arms the delayed flush, and the
    /// index it writes is the store's.
    @Test(arguments: MutationPath.allCases)
    func everyMutationPathArmsTheDelayedFlush(_ path: MutationPath) throws {
        let store = try open(limit: 100)
        try store.write(bytes(10), for: "a", tier: .speculative)
        try store.write(bytes(10), for: "b")
        clock.advance(by: 3)
        scheduler.runUntilIdle()
        let before = store.statistics.indexWrites
        #expect(before == 1, "precondition: written and quiet")

        var lease: CacheLease?
        switch path {
        case .write:
            try store.write(bytes(10), for: "c")
        case .moveItem:
            let source = folder.url.appending(path: "download.tmp")
            try bytes(10).write(to: source)
            try store.moveItem(at: source, for: "c")
        case .read:
            _ = store.data(for: "a")
        case .fileURL:
            _ = store.fileURL(for: "a")
        case .lease:
            lease = store.lease("a")
        case .leaseEndEviction:
            lease = store.lease("a")
            clock.advance(by: 3)
            scheduler.runUntilIdle()
            store.setLimits(CacheLimits(bytes: 5, speculativeBytes: 5))
            clock.advance(by: 3)
            scheduler.runUntilIdle()
            #expect(store.contains("a"), "precondition: leased, so kept over the limit")
            #expect(!store.contains("b"), "precondition: the unleased one went")
            let written = store.statistics.indexWrites
            lease?.release()
            lease = nil
            #expect(!store.contains("a"), "evicted as its lease ended")
            #expect(scheduler.pendingDelays.count == 1, "\(path): armed")
            clock.advance(by: 3)
            scheduler.runUntilIdle()
            #expect(store.statistics.indexWrites == written + 1)
            #expect(indexedKeys().isEmpty)
            return
        case .setTier:
            store.setTier(.retained, for: "b")
        case .removeValue:
            store.removeValue(for: "b")
        case .removeAll:
            store.removeAll()
            DiskStore.drainJanitor()
        case .setLimitsEviction:
            store.setLimits(CacheLimits(bytes: 10, speculativeBytes: 10))
        case .trim:
            store.trim(.speculative)
        case .expiry:
            clock.advance(by: CacheTier.speculativeLifetime + 1)
            _ = store.data(for: "a")
        case .vanishedFile:
            let url = try #require(store.fileURL(for: "b"))
            clock.advance(by: 3)
            scheduler.runUntilIdle()
            try FileManager.default.removeItem(at: url)
            #expect(store.data(for: "b") == nil)
        }
        let written = store.statistics.indexWrites
        #expect(scheduler.pendingDelays.count == 1, "\(path): armed")
        clock.advance(by: 10)
        scheduler.runUntilIdle()
        // A wipe writes its own index once its files are gone (the janitor);
        // the armed flush then finds nothing to do.
        #expect(store.statistics.indexWrites == (path == .removeAll ? written : written + 1), "\(path): one write")
        #expect(indexedKeys() == store.storedKeys, "\(path): the index on disk is the store's")
        withExtendedLifetime(lease) {}
    }
}

/// Holds scheduled work until the test runs it.
final class ManualFlushScheduler: CacheFlushScheduling {
    private let pending = Mutex<[(delay: TimeInterval, work: @Sendable () -> Void)]>([])

    func schedule(after delay: TimeInterval, _ work: @escaping @Sendable () -> Void) {
        pending.withLock { $0.append((delay, work)) }
    }

    var pendingDelays: [TimeInterval] { pending.withLock { $0.map(\.delay) } }

    /// Runs what was scheduled so far, once; what it schedules waits.
    func runPending() {
        let due = pending.withLock { items -> [@Sendable () -> Void] in
            defer { items.removeAll() }
            return items.map(\.work)
        }
        for work in due { work() }
    }

    /// Runs until nothing re-arms (bounded: a flush re-arms at most once
    /// per deadline the clock has not reached).
    func runUntilIdle() {
        for _ in 0..<10 where !pendingDelays.isEmpty {
            runPending()
        }
    }
}
