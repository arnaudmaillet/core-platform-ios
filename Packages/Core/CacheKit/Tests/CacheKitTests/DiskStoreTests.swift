import Foundation
import Testing
@testable import CacheKit

/// The disk store: files, index, versions, recovery, tiers, leases (#891).
final class DiskStoreTests {
    private let folder = TemporaryFolder()
    private let clock = ManualCacheClock()

    private func open(
        _ name: String = "media",
        version: Int = 1,
        limit: Int = 1_000,
        speculativeLimit: Int? = nil,
        idleLifetime: TimeInterval? = nil,
        flushThreshold: Int = 32
    ) throws -> DiskStore {
        try DiskStore(
            namespace: namespace(name),
            version: version,
            budget: DiskBudget(pool: .images),
            root: folder.url,
            limits: CacheLimits(bytes: limit, speculativeBytes: speculativeLimit ?? limit),
            clock: clock,
            idleLifetime: idleLifetime,
            flushThreshold: flushThreshold
        )
    }

    private func objectFiles(_ name: String = "media", version: Int = 1) -> [String] {
        folder.files(in: "\(name)/v\(version)/objects")
    }

    @Test func writesAndReadsBack() throws {
        let store = try open()
        #expect(try store.write(bytes(10, 1), for: "a"))
        #expect(store.data(for: "a") == bytes(10, 1))
        #expect(store.contains("a"))
        #expect(store.data(for: "missing") == nil)
        #expect(store.usage.bytes == 10)
        #expect(objectFiles().count == 1)
        #expect(store.directory.lastPathComponent == "v1")
    }

    /// A store whose reader goes by the extension (a player, #898) names
    /// every file with it, across a relaunch.
    @Test func aFileExtensionIsGivenToEveryFileAndSurvivesARelaunch() throws {
        func clips() throws -> DiskStore {
            try DiskStore(namespace: namespace("clips"), budget: DiskBudget(pool: .video), root: folder.url, clock: clock, fileExtension: "mp4")
        }
        var store: DiskStore? = try clips()
        try store?.write(bytes(10), for: "written")
        let source = folder.url.appending(path: "moved.tmp")
        try bytes(12).write(to: source)
        try store?.moveItem(at: source, for: "moved")
        #expect(store?.fileURL(for: "written")?.pathExtension == "mp4")
        #expect(store?.fileURL(for: "moved")?.pathExtension == "mp4")
        store?.flush()
        store = nil

        let relaunched = try clips()
        #expect(relaunched.data(for: "written") == bytes(10))
        #expect(relaunched.data(for: "moved") == bytes(12))
        #expect(folder.files(in: "clips/v1/objects").allSatisfy { $0.hasSuffix(".mp4") })
    }

    @Test func writesAreAtomicAndLeaveNoStagedFile() throws {
        let store = try open()
        try store.write(bytes(10), for: "a")
        try store.write(bytes(12), for: "a")
        #expect(folder.files(in: "media/v1/incoming").isEmpty)
        #expect(objectFiles().count == 1, "the replaced file is gone")
        #expect(store.data(for: "a")?.count == 12)
    }

    @Test func byteBudgetEvictsTheLeastRecentlyUsedFiles() throws {
        let store = try open(limit: 30)
        try store.write(bytes(10), for: "a")
        try store.write(bytes(10), for: "b")
        try store.write(bytes(10), for: "c")
        _ = store.data(for: "a")
        try store.write(bytes(10), for: "d")
        #expect(!store.contains("b"), "b was the least recently used")
        #expect(store.contains("a") && store.contains("c") && store.contains("d"))
        #expect(objectFiles().count == 3, "its file is deleted from disk")
        #expect(store.usage.bytes == 30)
    }

    @Test func evictionOrderIsSpeculativeThenRecentThenRetained() throws {
        let store = try open(limit: 40)
        try store.write(bytes(10), for: "retained", tier: .retained)
        try store.write(bytes(10), for: "recent-old")
        try store.write(bytes(10), for: "speculative", tier: .speculative)
        try store.write(bytes(10), for: "recent-new")
        store.setLimits(CacheLimits(bytes: 30, speculativeBytes: 30))
        #expect(!store.contains("speculative"))
        store.setLimits(CacheLimits(bytes: 20, speculativeBytes: 20))
        #expect(!store.contains("recent-old"))
        store.setLimits(CacheLimits(bytes: 10, speculativeBytes: 10))
        #expect(!store.contains("recent-new"))
        #expect(store.contains("retained"))
        #expect(objectFiles().count == 1)
    }

    @Test func anEntryBiggerThanTheBudgetLeavesNothingOnDisk() throws {
        let store = try open(limit: 10, speculativeLimit: 0)
        #expect(try !store.write(bytes(11), for: "big"))
        #expect(try !store.write(bytes(5), for: "prefetch", tier: .speculative), "the speculative cap is 0")
        #expect(objectFiles().isEmpty)
        #expect(folder.files(in: "media/v1/incoming").isEmpty)
    }

    @Test func theIndexSurvivesARelaunch() throws {
        var store: DiskStore? = try open()
        try store?.write(bytes(10, 1), for: "retained", tier: .retained)
        try store?.write(bytes(11, 2), for: "recent-a")
        try store?.write(bytes(12, 3), for: "recent-b")
        try store?.write(bytes(13, 4), for: "prefetch", tier: .speculative)
        _ = store?.data(for: "recent-a")
        // What the background flush does before the app is suspended.
        store?.flush()
        store = nil

        let reopened = try open()
        #expect(reopened.usage.count == 4)
        #expect(reopened.usage.bytes == 46)
        #expect(reopened.tier(of: "retained") == .retained)
        #expect(reopened.tier(of: "prefetch") == .speculative)
        #expect(reopened.orderedKeys(in: .recent) == ["recent-b", "recent-a"], "LRU order kept")
        #expect(reopened.data(for: "recent-b") == bytes(12, 3))
    }

    @Test func unflushedWritesLeaveNoOrphanAfterACrash() throws {
        var store: DiskStore? = try open(flushThreshold: 1_000)
        try store?.write(bytes(10), for: "flushed")
        store?.flush()
        try store?.write(bytes(10), for: "unflushed")
        // Killed: no flush, no deinit work.
        store = nil

        let reopened = try open()
        #expect(reopened.contains("flushed"))
        #expect(!reopened.contains("unflushed"), "the index never named it")
        #expect(objectFiles().count == 1, "its file was deleted as an orphan")
        #expect(reopened.usage.bytes == 10)
    }

    @Test func aCorruptIndexStartsEmptyAndDeletesTheUnnamedFiles() throws {
        var store: DiskStore? = try open()
        try store?.write(bytes(10), for: "a")
        try store?.write(bytes(10), for: "b")
        store?.flush()
        let index = try #require(store?.directory.appending(path: "index.json"))
        store = nil
        try Data("{ not json".utf8).write(to: index)

        let reopened = try open()
        #expect(reopened.usage.count == 0)
        #expect(objectFiles().isEmpty)
        // And it works again, durably.
        try reopened.write(bytes(4), for: "c")
        reopened.flush()
        let again = try open()
        #expect(again.data(for: "c") == bytes(4))
    }

    @Test func anEntryWhoseFileVanishedIsDropped() throws {
        var store: DiskStore? = try open()
        try store?.write(bytes(10), for: "a")
        try store?.write(bytes(10), for: "b")
        store?.flush()
        let directory = try #require(store?.directory)
        let victim = try #require(store?.fileURL(for: "a"))
        store = nil
        try FileManager.default.removeItem(at: victim)

        let reopened = try open()
        #expect(!reopened.contains("a"))
        #expect(reopened.contains("b"))

        // At run time too (iOS purging Caches behind our back).
        let other = try #require(reopened.fileURL(for: "b"))
        try FileManager.default.removeItem(at: other)
        #expect(reopened.data(for: "b") == nil)
        #expect(!reopened.contains("b"))
        #expect(directory == reopened.directory)
    }

    @Test func anUnknownVersionFolderIsDeletedAtStartUp() throws {
        let namespaceFolder = folder.url.appending(path: "media", directoryHint: .isDirectory)
        let oldVersion = namespaceFolder.appending(path: "v1/objects", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: oldVersion, withIntermediateDirectories: true)
        try bytes(5).write(to: oldVersion.appending(path: "old"))
        try bytes(5).write(to: namespaceFolder.appending(path: "stray"))

        let store = try open(version: 2)
        #expect(folder.files(in: "media") == ["v2"])
        #expect(store.usage.count == 0)
    }

    @Test func theNamespaceFolderIsExcludedFromBackup() throws {
        _ = try open()
        let values = try folder.url.appending(path: "media").resourceValues(forKeys: [.isExcludedFromBackupKey])
        #expect(values.isExcludedFromBackup == true)
    }

    @Test func anInvalidNamespaceNameIsRefused() {
        #expect(throws: DiskStore.StoreError.invalidNamespaceName("../escape")) {
            try self.open("../escape")
        }
        #expect(throws: DiskStore.StoreError.invalidNamespaceName("")) {
            try self.open("")
        }
    }

    @Test func aSpeculativeEntryExpiresAfter24HoursAcrossARelaunch() throws {
        var store: DiskStore? = try open()
        try store?.write(bytes(10), for: "prefetch", tier: .speculative)
        try store?.write(bytes(10), for: "seen")
        store?.flush()
        store = nil
        clock.advance(by: CacheTier.speculativeLifetime + 1)

        let reopened = try open()
        #expect(!reopened.contains("prefetch"))
        #expect(reopened.contains("seen"))
        #expect(objectFiles().count == 1)
    }

    @Test func aSpeculativeEntryUsedOnceNoLongerExpires() throws {
        let store = try open()
        try store.write(bytes(10), for: "prefetch", tier: .speculative)
        #expect(store.data(for: "prefetch") != nil)
        #expect(store.tier(of: "prefetch") == .recent)
        clock.advance(by: 2 * CacheTier.speculativeLifetime)
        #expect(store.data(for: "prefetch") != nil)
    }

    @Test func expiredEntriesGoOnTheExpiredTrim() throws {
        let store = try open()
        try store.write(bytes(10), for: "prefetch", tier: .speculative)
        try store.write(bytes(10), for: "signed", expiresAt: clock.now.addingTimeInterval(60))
        try store.write(bytes(10), for: "kept", tier: .retained)
        clock.advance(by: CacheTier.speculativeLifetime + 1)
        store.trim(.expired)
        #expect(store.usage.count == 1)
        #expect(objectFiles().count == 1)
        #expect(store.statistics.expirations == 2)
    }

    @Test func idleLifetimeExpiresEntriesNobodyUsed() throws {
        let store = try open(idleLifetime: 30 * 24 * 3600)
        try store.write(bytes(10), for: "used", tier: .retained)
        try store.write(bytes(10), for: "idle", tier: .retained)
        clock.advance(by: 20 * 24 * 3600)
        _ = store.data(for: "used")
        clock.advance(by: 15 * 24 * 3600)
        store.trim(.expired)
        #expect(store.contains("used"))
        #expect(!store.contains("idle"))
    }

    @Test func aLeasedFileSurvivesEveryTrimAndAnyBudget() throws {
        let store = try open()
        try store.write(bytes(10), for: "playing", tier: .speculative)
        try store.write(bytes(10), for: "other")
        let lease = try #require(store.lease("playing"))
        #expect(store.tier(of: "playing") == .recent)
        for depth in TrimDepth.allCases {
            store.trim(depth)
            #expect(store.contains("playing"), "survives \(depth)")
        }
        store.setLimits(CacheLimits(bytes: 0, speculativeBytes: 0))
        #expect(store.data(for: "playing") != nil)
        #expect(!store.contains("other"))
        #expect(store.usage.pinnedBytes == 10)
        lease.release()
        #expect(!store.contains("playing"), "over budget once released")
        #expect(objectFiles().isEmpty)
    }

    @Test func aWipeHidesALeasedFileAndDeletesItOnRelease() throws {
        let store = try open()
        try store.write(bytes(10), for: "playing")
        let path = try #require(store.fileURL(for: "playing"))
        let lease = try #require(store.lease("playing"))
        store.removeAll()
        #expect(!store.contains("playing"), "never served again")
        #expect(FileManager.default.fileExists(atPath: path.path), "the player still reads it")
        #expect(store.usage.bytes == 10)
        lease.release()
        #expect(!FileManager.default.fileExists(atPath: path.path))
        #expect(store.usage.bytes == 0)
    }

    /// A lease that ends puts its entry back in its tier ONCE: its bytes are
    /// counted once, nothing stays pinned, and a wipe leaves zero (#1068).
    /// Every played video and song ends a lease, so a double count inflated
    /// Settings → Storage and left bytes behind every clear.
    @Test func anEndedLeaseCountsItsEntryOnceAndPinsNothing() throws {
        let store = try open()
        try store.write(bytes(10), for: "played", tier: .retained)
        try store.write(bytes(20), for: "other")
        let lease = try #require(store.lease("played"))
        #expect(store.usage.bytes == 30)
        #expect(store.usage.pinnedBytes == 10)
        lease.release()
        #expect(store.usage.bytes == 30, "the released entry is counted twice")
        #expect(store.usage.pinnedBytes == 0, "a released entry stayed pinned")
        #expect(store.usage.bytesByTier == [.retained: 10, .recent: 20])
        store.removeAll()
        #expect(store.usage.bytes == 0 && store.usage.pinnedBytes == 0, "a wipe left bytes behind")

        // A lease ended under a budget it no longer fits evicts it, once.
        try store.write(bytes(10), for: "played", tier: .retained)
        let again = try #require(store.lease("played"))
        store.setLimits(CacheLimits(bytes: 0, speculativeBytes: 0))
        again.release()
        #expect(!store.contains("played"))
        #expect(store.usage.bytes == 0 && store.usage.pinnedBytes == 0, "an eviction at release left bytes behind")
    }

    // MARK: - Wipes off the caller's thread (#898)

    private func trashFolders(_ name: String = "media", version: Int = 1) -> [String] {
        folder.files(in: "\(name)/v\(version)").filter { $0.hasPrefix(DiskStore.trashPrefix) }
    }

    @Test func aWipeReturnsAtOnceAndServesNothingAfterwards() throws {
        let store = try open()
        try store.write(bytes(10), for: "a")
        try store.write(bytes(10), for: "b")

        store.removeAll()

        #expect(!store.contains("a") && !store.contains("b"))
        #expect(store.data(for: "a") == nil && store.fileURL(for: "b") == nil)
        #expect(objectFiles().isEmpty, "the folder is swapped out before the call returns")
        #expect(store.usage.bytes == 0 && store.usage.count == 0)
        DiskStore.drainJanitor()
    }

    @Test func theWipedFilesAreEventuallyDeleted() throws {
        let store = try open()
        try store.write(bytes(10), for: "a")
        store.flush()

        store.removeAll()
        DiskStore.drainJanitor()

        #expect(trashFolders().isEmpty)
        #expect(objectFiles().isEmpty)
        let reopened = try open()
        #expect(!reopened.contains("a"), "the flushed index forgot it too")
    }

    @Test func aWriteThatLandsDuringABackgroundWipeSurvives() throws {
        let store = try open()
        try store.write(bytes(10, 1), for: "old")
        // Holds the janitor, so the wipe's deletion is still pending while
        // the next write commits.
        let held = DispatchSemaphore(value: 0)
        DiskStore.janitor.async { held.wait() }

        store.removeAll()
        #expect(try store.write(bytes(12, 2), for: "new"))
        held.signal()
        DiskStore.drainJanitor()

        #expect(store.data(for: "new") == bytes(12, 2))
        #expect(!store.contains("old"))
        #expect(objectFiles().count == 1)
    }

    @Test func trashLeftByACrashIsDeletedAtStartUp() throws {
        _ = try open()
        let trash = folder.url.appending(path: "media/v1/\(DiskStore.trashPrefix)crashed", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
        try bytes(10).write(to: trash.appending(path: "orphan"))

        let store = try open()
        DiskStore.drainJanitor()

        #expect(trashFolders().isEmpty)
        #expect(store.usage.count == 0)
    }

    @Test func replacingALeasedEntryKeepsTheOldFileUntilRelease() throws {
        let store = try open()
        try store.write(bytes(10, 1), for: "a")
        let oldPath = try #require(store.fileURL(for: "a"))
        let lease = try #require(store.lease("a"))
        try store.write(bytes(12, 2), for: "a")
        #expect(store.data(for: "a") == bytes(12, 2))
        #expect(FileManager.default.fileExists(atPath: oldPath.path))
        #expect(!store.isLeased("a"), "the new entry is not the leased file")
        lease.release()
        #expect(!FileManager.default.fileExists(atPath: oldPath.path))
        #expect(objectFiles().count == 1)
    }

    @Test func moveItemConsumesTheSource() throws {
        let store = try open()
        let download = folder.url.appending(path: "download.tmp")
        try bytes(9, 3).write(to: download)
        #expect(try store.moveItem(at: download, for: "dl"))
        #expect(!FileManager.default.fileExists(atPath: download.path))
        #expect(store.data(for: "dl") == bytes(9, 3))
    }

    @Test func removeValueDeletesTheFile() throws {
        let store = try open()
        try store.write(bytes(10), for: "a")
        store.removeValue(for: "a")
        #expect(!store.contains("a"))
        #expect(objectFiles().isEmpty)
    }
}
