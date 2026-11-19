import AuthInterface
import CacheKit
import CoreModels
import Foundation
import Testing
import UIKit

/// The app's cache coordinator hears the release signals from the REAL
/// sources (`AppCacheSignals`: UIKit's notifications, posted on a private
/// `NotificationCenter`, and the viewer's changes, published on a private
/// `ViewerEvents`): nothing process-wide is posted or flipped.
@MainActor
final class AppCacheSignalsTests {
    private let center = NotificationCenter()
    private let viewerEvents = ViewerEvents()
    private let folder: URL

    init() throws {
        folder = FileManager.default.temporaryDirectory
            .appending(path: "AppCacheSignalsTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: folder)
    }

    private func makeCoordinator() -> CacheCoordinator {
        let coordinator = CacheCoordinator(
            device: CacheDevice(physicalMemory: { 4 << 30 }, availableDiskCapacity: { 100 * Int64(CacheBytes.gigabyte) }),
            storageLimit: .automatic
        )
        coordinator.startObserving(
            AppCacheSignals.sources(center: center, viewerEvents: viewerEvents, observesSystemMonitors: false)
        )
        return coordinator
    }

    private func memory(_ name: String, scope: CacheScope) -> MemoryCache<String, String> {
        MemoryCache(
            namespace: CacheNamespace(name, category: .images, scope: scope),
            budget: .fixed(bytes: 1_000)
        )
    }

    private func disk(_ name: String, scope: CacheScope) throws -> DiskStore {
        try DiskStore(
            namespace: CacheNamespace(name, category: .images, scope: scope),
            budget: DiskBudget(pool: .images),
            root: folder,
            flushThreshold: 1_000
        )
    }

    @Test func aMemoryWarningFromUIKitTrimsMemoryAndLeavesDiskAlone() throws {
        let coordinator = makeCoordinator()
        defer { coordinator.stopObserving() }
        let images = memory("decoded", scope: .public)
        let bytes = try disk("bytes", scope: .public)
        coordinator.register(images)
        coordinator.register(bytes)
        images.insert("s", for: "s", cost: 1, tier: .speculative)
        images.insert("t", for: "t", cost: 1, tier: .retained)
        try bytes.write(Data([1]), for: "s", tier: .speculative)

        center.post(name: UIApplication.didReceiveMemoryWarningNotification, object: nil)

        #expect(!images.contains("s"), "speculative decoded images go on a warning")
        #expect(images.contains("t"), "retained ones stay")
        #expect(bytes.contains("s"), "a memory warning never touches disk")
    }

    @Test func goingToTheBackgroundTrimsMemoryToRetainedAndFlushesDiskIndexes() throws {
        let coordinator = makeCoordinator()
        defer { coordinator.stopObserving() }
        let images = memory("decoded", scope: .public)
        let bytes = try disk("bytes", scope: .public)
        coordinator.register(images)
        coordinator.register(bytes)
        images.insert("r", for: "r", cost: 1)
        images.insert("t", for: "t", cost: 1, tier: .retained)
        try bytes.write(Data([1]), for: "seen")
        let index = bytes.directory.appending(path: "index.json")
        #expect(!((try? String(contentsOf: index, encoding: .utf8)) ?? "").contains("seen"), "not flushed yet")

        center.post(name: UIApplication.didEnterBackgroundNotification, object: nil)

        #expect(!images.contains("r") && images.contains("t"))
        #expect(bytes.contains("seen"))
        #expect(((try? String(contentsOf: index, encoding: .utf8)) ?? "").contains("seen"), "the disk index is flushed")
    }

    @Test func aViewerTransitionWipesViewerAndSignedNamespacesAndKeepsPublicMedia() throws {
        let coordinator = makeCoordinator()
        defer { coordinator.stopObserving() }
        let publicBytes = try disk("public", scope: .public)
        let signedBytes = try disk("signed", scope: .signed)
        let entities = memory("entities", scope: .viewer)
        for cache in [publicBytes, signedBytes, entities] as [any ManagedCache] { coordinator.register(cache) }
        try publicBytes.write(Data([1]), for: "k")
        try signedBytes.write(Data([1]), for: "k")
        entities.insert("v", for: "k", cost: 1)

        viewerEvents.publishViewerChange()

        #expect(publicBytes.contains("k"))
        #expect(!signedBytes.contains("k"))
        #expect(!entities.contains("k"))
    }

    /// ⚠️ THE WIPE COMES FIRST (#2376). A screen that re-reads on a viewer
    /// change — even one that subscribed before the coordinator started —
    /// finds the previous viewer's facts already gone, on the same turn, and
    /// a fact it writes for the new viewer is not wiped after it.
    @Test func theViewerWipeRunsBeforeEveryObserverWhenEverItSubscribed() throws {
        let entities = memory("entities", scope: .viewer)
        let seen = Seen()
        let early = viewerEvents.onViewerChange {
            seen.early.append(entities.contains("k"))
            // The new viewer's first fact, written as it re-reads.
            entities.insert("new", for: "fresh", cost: 1)
        }
        let coordinator = makeCoordinator()
        defer { coordinator.stopObserving() }
        coordinator.register(entities)
        entities.insert("v", for: "k", cost: 1)
        let late = viewerEvents.onViewerChange { seen.late.append(entities.contains("k")) }

        viewerEvents.publishViewerChange()

        #expect(seen.early == [false], "an observer read the previous viewer's fact")
        #expect(seen.late == [false])
        #expect(entities.contains("fresh"), "the new viewer's first fact was wiped after it was written")
        withExtendedLifetime((early, late)) {}
    }

    /// What each observer saw of the previous viewer's fact.
    @MainActor
    private final class Seen {
        var early: [Bool] = []
        var late: [Bool] = []
    }

    @Test func nothingIsHeardAfterStopObserving() {
        let coordinator = makeCoordinator()
        let images = memory("decoded", scope: .viewer)
        coordinator.register(images)
        coordinator.stopObserving()
        images.insert("s", for: "s", cost: 1, tier: .speculative)

        center.post(name: UIApplication.didReceiveMemoryWarningNotification, object: nil)
        viewerEvents.publishViewerChange()

        #expect(images.contains("s"))
    }
}
