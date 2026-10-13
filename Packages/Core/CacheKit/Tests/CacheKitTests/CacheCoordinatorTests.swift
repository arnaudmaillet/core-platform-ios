import Foundation
import Synchronization
import Testing
@testable import CacheKit

/// The coordinator: budgets per namespace, usage, and its reaction to every
/// signal, all through injected seams (no process-wide state).
final class CacheCoordinatorTests {
    private let folder = TemporaryFolder()
    private let clock = ManualCacheClock()
    private let fake = FakeDevice()

    private func disk(_ name: String, _ budget: DiskBudget, scope: CacheScope = .public, category: CacheCategory = .images, priorityClass: CachePriorityClass = .standard, flushThreshold: Int = 32) throws -> DiskStore {
        try DiskStore(
            namespace: namespace(name, category, scope: scope, priorityClass: priorityClass),
            budget: budget,
            root: folder.url,
            clock: clock,
            flushThreshold: flushThreshold
        )
    }

    private func memory(_ name: String, _ budget: MemoryBudget = .fixed(bytes: 1_000), scope: CacheScope = .public, category: CacheCategory = .images, priorityClass: CachePriorityClass = .standard) -> MemoryCache<String, String> {
        MemoryCache(namespace: namespace(name, category, scope: scope, priorityClass: priorityClass), budget: budget, clock: clock)
    }

    private func makeCoordinator(limit: CacheStorageLimit = .automatic, conditions: CacheConditions = CacheConditions()) -> CacheCoordinator {
        CacheCoordinator(device: fake.device, storageLimit: limit, conditions: conditions)
    }

    // MARK: - Budgets

    @Test func registrationAppliesTheDeviceBudgets() throws {
        let coordinator = makeCoordinator()
        let decoded = memory("decoded", .decodedImages)
        let images = try disk("images", DiskBudget(pool: .images))
        let video = try disk("video", DiskBudget(pool: .video), category: .videos)
        let store = try disk("localstore", DiskBudget(pool: .localStore), category: .other)
        for cache in [decoded, images, video, store] as [any ManagedCache] { coordinator.register(cache) }

        #expect(decoded.limits.bytes == Int(Double(4 << 30) * 0.05))
        #expect(images.limits == CacheLimits(bytes: 300 * megabyte, speculativeBytes: 60 * megabyte))
        #expect(video.limits == CacheLimits(bytes: 500 * megabyte, speculativeBytes: 100 * megabyte))
        #expect(store.limits.bytes == 100 * megabyte)
        #expect(coordinator.limits(for: video) == video.limits)
    }

    @Test func aPoolIsSharedByWeightAfterTheReservations() throws {
        let coordinator = makeCoordinator()
        let emotes = try disk("emotes", .reserved(64 * megabyte, in: .images), priorityClass: .persistent)
        let images = try disk("images", DiskBudget(pool: .images, weight: 3))
        let signed = try disk("images-signed", DiskBudget(pool: .images, weight: 1), scope: .signed)
        coordinator.register(emotes)
        coordinator.register(images)
        coordinator.register(signed)
        #expect(emotes.limits.bytes == 64 * megabyte)
        #expect(images.limits.bytes == 177 * megabyte)
        #expect(signed.limits.bytes == 59 * megabyte)

        coordinator.unregister(signed)
        #expect(images.limits.bytes == 236 * megabyte, "an unregistered namespace gives its share back")
    }

    @Test func aFixedUserLimitSplits3To5To1AcrossTheNamespaces() throws {
        let coordinator = makeCoordinator()
        let images = try disk("images", DiskBudget(pool: .images))
        let video = try disk("video", DiskBudget(pool: .video), category: .videos)
        let store = try disk("localstore", DiskBudget(pool: .localStore), category: .other)
        for cache in [images, video, store] { coordinator.register(cache) }

        coordinator.setStorageLimit(.oneGigabyte)
        #expect(coordinator.storageLimit == .oneGigabyte)
        #expect(images.limits.bytes == 333_333_333)
        #expect(video.limits.bytes == 555_555_555)
        #expect(store.limits.bytes == 111_111_111)
        #expect(images.limits.bytes + video.limits.bytes + store.limits.bytes <= CacheBytes.gigabyte)
    }

    @Test func aShrunkLimitEvictsAtOnce() throws {
        let coordinator = makeCoordinator()
        let video = try disk("video", DiskBudget(pool: .video), category: .videos)
        coordinator.register(video)
        try video.write(bytes(1_000), for: "a")
        coordinator.setStorageLimit(.total(bytes: 900))
        #expect(video.limits.bytes == 500)
        #expect(!video.contains("a"))
    }

    @Test func reportsBytesPerNamespaceAndPerCategory() throws {
        let coordinator = makeCoordinator()
        let decoded = memory("decoded")
        let images = try disk("images", DiskBudget(pool: .images))
        let video = try disk("video", DiskBudget(pool: .video), category: .videos)
        let messages = memory("messages", category: .messages, priorityClass: .preferred)
        for cache in [decoded, images, video, messages] as [any ManagedCache] { coordinator.register(cache) }
        decoded.insert("x", for: "x", cost: 40)
        try images.write(bytes(100), for: "i")
        try video.write(bytes(300), for: "v")
        messages.insert("m", for: "m", cost: 7)

        let report = coordinator.usage()
        #expect(report.usage(of: "decoded", medium: .memory)?.bytes == 40)
        #expect(report.usage(of: "images", medium: .disk)?.bytes == 100)
        #expect(report.bytes(in: .images) == 140)
        #expect(report.bytes(in: .images, medium: .disk) == 100)
        #expect(report.bytes(in: .videos) == 300)
        #expect(report.bytes(in: .messages) == 7)
        #expect(report.bytesByCategory == [.images: 140, .videos: 300, .sounds: 0, .messages: 7, .other: 0])
        #expect(report.totalBytes(medium: .memory) == 47)
        #expect(report.totalBytes() == 447)
    }

    @Test func registeringTheSameNameAndMediumReplacesTheOldCache() throws {
        let coordinator = makeCoordinator()
        coordinator.register(memory("decoded"))
        let replacement = memory("decoded")
        coordinator.register(replacement)
        coordinator.register(try disk("decoded", DiskBudget(pool: .images)))
        #expect(coordinator.registeredCaches.count == 2)
        #expect(coordinator.registeredCaches.contains { $0 === replacement })
    }

    // MARK: - Memory signals

    @Test func aMemoryWarningTrimsMemoryByClassAndLeavesDiskAlone() throws {
        let coordinator = makeCoordinator()
        let feed = memory("feed")
        let emotes = memory("emotes", priorityClass: .persistent)
        let previews = memory("previews", priorityClass: .expendable)
        let images = try disk("images", DiskBudget(pool: .images))
        for cache in [feed, emotes, previews, images] as [any ManagedCache] { coordinator.register(cache) }
        for cache in [feed, emotes, previews] {
            cache.insert("s", for: "s", cost: 10, tier: .speculative)
            cache.insert("r1", for: "r1", cost: 10)
            cache.insert("r2", for: "r2", cost: 10)
            cache.insert("t", for: "t", cost: 10, tier: .retained)
        }
        try images.write(bytes(10), for: "prefetch", tier: .speculative)

        coordinator.trim(.memoryWarning)
        #expect(feed.orderedKeys(in: .speculative).isEmpty)
        #expect(feed.orderedKeys(in: .recent) == ["r2"], "standard: half of recent")
        #expect(emotes.usage.count == 3, "persistent: speculative only")
        #expect(!emotes.contains("s"))
        #expect(previews.usage.count == 1 && previews.contains("t"), "expendable: down to retained")
        #expect(images.contains("prefetch"), "disk untouched by a memory warning")
    }

    @Test func criticalMemoryKeepsOnlyPinnedButPersistentKeepsRetained() {
        let coordinator = makeCoordinator()
        let feed = memory("feed")
        let emotes = memory("emotes", priorityClass: .persistent)
        coordinator.register(feed)
        coordinator.register(emotes)
        for cache in [feed, emotes] {
            cache.insert("r", for: "r", cost: 10)
            cache.insert("t", for: "t", cost: 10, tier: .retained)
            cache.insert("p", for: "p", cost: 10)
        }
        let feedLease = feed.lease("p")
        let emoteLease = emotes.lease("p")

        coordinator.trim(.memoryCritical)
        #expect(feed.usage.count == 1 && feed.contains("p"))
        #expect(emotes.usage.count == 2 && emotes.contains("t") && emotes.contains("p"))
        feedLease?.release()
        emoteLease?.release()
    }

    @Test func backgroundTrimsMemoryToRetainedAndFlushesDiskIndexes() throws {
        let coordinator = makeCoordinator()
        let feed = memory("feed")
        var images: DiskStore? = try disk("images", DiskBudget(pool: .images), flushThreshold: 1_000)
        coordinator.register(feed)
        coordinator.register(try #require(images))
        feed.insert("r", for: "r", cost: 10)
        feed.insert("t", for: "t", cost: 10, tier: .retained)
        try images?.write(bytes(10), for: "kept")
        try images?.write(bytes(10), for: "prefetch", tier: .speculative)
        clock.advance(by: CacheTier.speculativeLifetime + 1)

        coordinator.trim(.background)
        #expect(feed.usage.count == 1 && feed.contains("t"))
        #expect(images?.contains("prefetch") == false, "expired entries swept")
        coordinator.unregister(try #require(images))
        images = nil

        let relaunched = try disk("images", DiskBudget(pool: .images))
        #expect(relaunched.contains("kept"), "the background flush made it durable")
    }

    // MARK: - Disk signals

    @Test func lowDiskShrinksDiskBudgetsInStepsAndRestoresThem() throws {
        let coordinator = makeCoordinator()
        let images = try disk("images", DiskBudget(pool: .images))
        let video = try disk("video", DiskBudget(pool: .video), category: .videos)
        coordinator.register(images)
        coordinator.register(video)
        try video.write(bytes(10), for: "watched")

        fake.setFreeDisk(4 * Int64(CacheBytes.gigabyte))
        #expect(coordinator.refreshDiskSpace() == .low)
        #expect(video.limits.bytes == 250 * megabyte)
        #expect(images.limits.bytes == 150 * megabyte)

        fake.setFreeDisk(Int64(CacheBytes.gigabyte) / 2)
        #expect(coordinator.refreshDiskSpace() == .critical)
        #expect(video.limits.bytes == 0)
        #expect(!video.contains("watched"), "the video cache is off")
        #expect(images.limits.bytes == 50 * megabyte)

        fake.setFreeDisk(100 * Int64(CacheBytes.gigabyte))
        coordinator.refreshDiskSpace()
        #expect(coordinator.diskPressure == .normal)
        #expect(video.limits.bytes == 500 * megabyte)
    }

    @Test func aPersistentReservationOutlivesLowDiskUntilTheLastResort() throws {
        let coordinator = makeCoordinator()
        let emotes = try disk("emotes", .reserved(64 * megabyte, in: .images), priorityClass: .persistent)
        let images = try disk("images", DiskBudget(pool: .images))
        coordinator.register(emotes)
        coordinator.register(images)

        coordinator.trim(.lowDisk(.low))
        #expect(emotes.limits.bytes == 64 * megabyte, "low disk shrinks the others")
        #expect(images.limits.bytes == 86 * megabyte)

        coordinator.trim(.lowDisk(.critical))
        #expect(emotes.limits.bytes == 50 * megabyte, "under 1 GB free: the pool itself is smaller")
        #expect(images.limits.bytes == 0)
    }

    // MARK: - Session and Settings

    @Test func aViewerChangeWipesViewerScopedAndSignedAndKeepsPublicMedia() throws {
        let coordinator = makeCoordinator()
        let publicDisk = try disk("images", DiskBudget(pool: .images))
        let signedDisk = try disk("images-signed", DiskBudget(pool: .images), scope: .signed)
        let viewerDisk = try disk("localstore", DiskBudget(pool: .localStore), scope: .viewer, category: .other)
        let publicMemory = memory("decoded")
        let viewerMemory = memory("entities", scope: .viewer, category: .other)
        for cache in [publicDisk, signedDisk, viewerDisk, publicMemory, viewerMemory] as [any ManagedCache] {
            coordinator.register(cache)
        }
        for store in [publicDisk, signedDisk, viewerDisk] { try store.write(bytes(10), for: "k") }
        publicMemory.insert("v", for: "k", cost: 1)
        viewerMemory.insert("v", for: "k", cost: 1)

        coordinator.trim(.viewerChanged)
        #expect(publicDisk.contains("k"))
        #expect(publicMemory.contains("k"))
        #expect(!signedDisk.contains("k"))
        #expect(!viewerDisk.contains("k"))
        #expect(!viewerMemory.contains("k"))
        #expect(folder.files(in: "images-signed/v1/objects").isEmpty, "signed bytes are deleted, not hidden")
    }

    @Test func aClearWipesOneCategoryOrEverythingPersistentIncluded() throws {
        let coordinator = makeCoordinator()
        let images = try disk("images", DiskBudget(pool: .images))
        let emotes = memory("emotes", priorityClass: .persistent)
        let video = try disk("video", DiskBudget(pool: .video), category: .videos)
        for cache in [images, emotes, video] as [any ManagedCache] { coordinator.register(cache) }
        try images.write(bytes(10), for: "k")
        emotes.insert("e", for: "k", cost: 1, tier: .retained)
        try video.write(bytes(10), for: "k")

        coordinator.trim(.clear(.images))
        #expect(!images.contains("k") && !emotes.contains("k"))
        #expect(video.contains("k"))
        coordinator.trim(.clear(nil))
        #expect(!video.contains("k"))
    }

    // MARK: - Signal sources

    @Test func eachSignalReachesItsReaction() throws {
        let coordinator = makeCoordinator()
        let signals = ManualCacheSignals()
        coordinator.startObserving([signals])
        defer { coordinator.stopObserving() }
        let feed = memory("feed")
        let viewer = memory("entities", scope: .viewer, category: .other)
        let video = try disk("video", DiskBudget(pool: .video), category: .videos, flushThreshold: 1_000)
        for cache in [feed, viewer, video] as [any ManagedCache] { coordinator.register(cache) }

        feed.insert("s", for: "s", cost: 1, tier: .speculative)
        signals.send(.memoryWarning)
        #expect(!feed.contains("s"))

        feed.insert("r", for: "r", cost: 1)
        feed.insert("t", for: "t", cost: 1, tier: .retained)
        signals.send(.didEnterBackground)
        #expect(!feed.contains("r") && feed.contains("t"))

        signals.send(.memoryCritical)
        #expect(!feed.contains("t"))

        fake.setFreeDisk(Int64(CacheBytes.gigabyte) / 2)
        signals.send(.willEnterForeground)
        #expect(coordinator.diskPressure == .critical, "the foreground re-measures free disk")
        #expect(video.limits.bytes == 0)

        signals.send(.lowPowerMode(true))
        #expect(coordinator.prefetchPolicy == .reduced)
        #expect(coordinator.fillSlots.limit == 0)
        signals.send(.lowPowerMode(false))
        signals.send(.thermalState(.critical))
        #expect(coordinator.prefetchPolicy == .off)
        signals.send(.thermalState(.nominal))
        signals.send(.network(.cellular, isConstrained: false, isExpensive: true))
        #expect(coordinator.prefetchPolicy == .cellular)
        #expect(coordinator.conditions.network == .cellular)
        signals.send(.network(.wifi, isConstrained: true, isExpensive: false))
        #expect(coordinator.prefetchPolicy == .reduced, "Low Data Mode")
        signals.send(.network(.wifi, isConstrained: false, isExpensive: false))
        #expect(coordinator.prefetchPolicy == .full)
        #expect(coordinator.fillSlots.limit == 2)

        viewer.insert("v", for: "v", cost: 1)
        signals.send(.viewerChanged)
        #expect(!viewer.contains("v"))

        coordinator.stopObserving()
        feed.insert("s", for: "s", cost: 1, tier: .speculative)
        signals.send(.memoryWarning)
        #expect(feed.contains("s"), "nothing after stopObserving")
    }

    // MARK: - Release paths (#898)

    /// The background turns prefetching off until the foreground: no P2 slot,
    /// a policy of `off` the lookaheads and the image pipeline read.
    @Test func theBackgroundStopsPrefetchingUntilTheForeground() {
        let coordinator = makeCoordinator()
        coordinator.handle(.didEnterBackground)
        #expect(coordinator.conditions.isInBackground)
        #expect(coordinator.prefetchPolicy == .off)
        #expect(coordinator.prefetchPolicy.videoPreloadDepth == 0)
        #expect(coordinator.fillSlots.limit == 0)

        coordinator.handle(.willEnterForeground)
        #expect(!coordinator.conditions.isInBackground)
        #expect(coordinator.prefetchPolicy == .full)
        #expect(coordinator.fillSlots.limit == PrefetchPolicy.full.maxConcurrentSpeculativeFills)
    }

    /// #900's review saw decoded images grow back after the background trim.
    /// What the background cut to `retained` (feed media: expendable and
    /// standard) admits nothing new below it until the foreground; leased and
    /// retained stores still land, and the classes it cuts less deep keep
    /// filling.
    @Test func theBackgroundHoldsWhatItCutUntilTheForeground() {
        let coordinator = makeCoordinator()
        let feed = memory("feed")
        let avatars = memory("avatars", priorityClass: .preferred)
        let emotes = memory("emotes", priorityClass: .persistent)
        for cache in [feed, avatars, emotes] as [any ManagedCache] { coordinator.register(cache) }

        coordinator.handle(.didEnterBackground)
        #expect(!feed.insert("late", for: "late", cost: 1), "a fill landing in the background is not kept")
        #expect(!feed.contains("late"))
        #expect(feed.insert("own", for: "own", cost: 1, tier: .retained), "the viewer's own content still lands")
        let shown = feed.insertLeased("shown", for: "shown", cost: 1)
        #expect(feed.contains("shown"), "and so does what is on screen")
        #expect(avatars.insert("face", for: "face", cost: 1))
        #expect(emotes.insert("sheet", for: "sheet", cost: 1))
        let registeredLate = memory("late-feed")
        coordinator.register(registeredLate)
        #expect(!registeredLate.insert("x", for: "x", cost: 1), "a namespace registered in the background is held too")

        coordinator.handle(.willEnterForeground)
        #expect(feed.insert("late", for: "late", cost: 1))
        #expect(registeredLate.insert("x", for: "x", cost: 1))
        shown.release()
    }

    /// Prefetch depth by signal: Wi-Fi 3, cellular 2; Low Data Mode, Use Less
    /// Cellular Data on cellular, Low Power or a serious thermal state 1 with
    /// no P2; a critical thermal state, offline or the background 0.
    @Test(arguments: [
        (CacheConditions(), 3, 2),
        (CacheConditions(network: .cellular, isNetworkExpensive: true), 2, 2),
        (CacheConditions(isNetworkConstrained: true), 1, 0),
        (CacheConditions(network: .cellular, usesLessCellularData: true), 1, 0),
        (CacheConditions(isLowPowerModeEnabled: true), 1, 0),
        (CacheConditions(thermalState: .serious), 1, 0),
        (CacheConditions(thermalState: .critical), 0, 0),
        (CacheConditions(network: .offline), 0, 0),
        (CacheConditions(isInBackground: true), 0, 0)
    ])
    func prefetchDepthFollowsEachSignal(conditions: CacheConditions, depth: Int, speculativeFills: Int) {
        let coordinator = makeCoordinator(conditions: conditions)
        #expect(coordinator.prefetchPolicy.videoPreloadDepth == depth)
        #expect(coordinator.fillSlots.limit == speculativeFills, "P2 fills app-wide")
    }

    /// Free disk is measured again on the way to the background too (a long
    /// recording can fill the disk while the app is in use).
    @Test func theBackgroundMeasuresFreeDiskAgain() throws {
        let coordinator = makeCoordinator()
        let video = try disk("video", DiskBudget(pool: .video), category: .videos)
        coordinator.register(video)
        fake.setFreeDisk(4 * Int64(CacheBytes.gigabyte))
        coordinator.handle(.didEnterBackground)
        #expect(coordinator.diskPressure == .low)
        #expect(video.limits.bytes == 250 * megabyte)
    }

    /// ⚠️ No disk work on the main thread: UIKit posts the lifecycle signals
    /// there, and the app makes its coordinator there. Memory is trimmed in
    /// place at once; whatever a signal asks of a
    /// disk cache (a sweep, a flush, budgets that delete files, the free-space
    /// measure) runs on the coordinator's queue.
    @MainActor
    @Test func diskCachesAreNeverCalledOnTheMainThread() {
        let measuredOnMain = FlagBox()
        let device = CacheDevice(physicalMemory: { 4 << 30 }, availableDiskCapacity: { [fake] in
            if Thread.isMainThread { measuredOnMain.set() }
            return fake.device.availableDiskCapacity()
        })
        let coordinator = CacheCoordinator(device: device)
        let recorder = RecordingDiskCache()
        let feed = memory("feed")
        coordinator.register(recorder)
        coordinator.register(feed)
        feed.insert("r", for: "r", cost: 1)

        coordinator.handle(.didEnterBackground)
        #expect(!feed.contains("r"), "memory is trimmed in place, at once")
        fake.setFreeDisk(Int64(CacheBytes.gigabyte) / 2)
        coordinator.handle(.willEnterForeground)
        coordinator.setStorageLimit(.halfGigabyte)
        coordinator.flush()
        coordinator.waitForDiskWork()

        let calls = recorder.calls
        #expect(calls.contains { $0.name == "trim" } && calls.contains { $0.name == "flush" })
        #expect(calls.contains { $0.name == "setLimits" })
        #expect(coordinator.diskPressure == .critical, "the foreground measured, off the main thread")
        #expect(calls.allSatisfy { !$0.onMainThread }, "called on main: \(calls.filter(\.onMainThread).map(\.name))")
        #expect(!measuredOnMain.value, "free disk was measured on the main thread")
    }

    @Test func aMemorySignalReachesThePressureObserversAndNothingElseDoes() {
        let coordinator = makeCoordinator()
        let heard = Mutex<[MemoryPressure]>([])
        let observation = coordinator.observeMemoryPressure { pressure in heard.withLock { $0.append(pressure) } }
        coordinator.trim(.memoryWarning)
        coordinator.trim(.background)
        coordinator.trim(.memoryCritical)
        coordinator.trim(.lowDisk(.low))
        coordinator.trim(.viewerChanged)
        coordinator.trim(.clear(nil))
        #expect(heard.withLock { $0 } == [.warning, .background, .critical])
        observation.cancel()
    }

    @Test func conditionObserversHearEveryPolicyChange() {
        let coordinator = makeCoordinator()
        let recorder = SignalRecorder()
        var observation: CacheObservation? = coordinator.observeConditions { conditions, policy in
            recorder.record(.lowPowerMode(conditions.isLowPowerModeEnabled))
            #expect(policy == PrefetchPolicy(conditions: conditions))
        }
        coordinator.handle(.lowPowerMode(true))
        coordinator.handle(.lowPowerMode(false))
        #expect(recorder.signals == [.lowPowerMode(true), .lowPowerMode(false)])
        observation?.cancel()
        observation = nil
        coordinator.handle(.lowPowerMode(true))
        #expect(recorder.signals.count == 2)
    }

    /// The Settings toggle reaches the coordinator through `updateConditions`:
    /// on cellular it stops every P2 fill at once and tells the lookaheads.
    @Test func useLessCellularDataOnCellularStopsSpeculativeFills() {
        let coordinator = makeCoordinator(conditions: CacheConditions(network: .cellular))
        #expect(coordinator.prefetchPolicy == .cellular)
        let recorder = SignalRecorder()
        let observation = coordinator.observeConditions { conditions, _ in
            recorder.record(.network(conditions.network, isConstrained: false, isExpensive: conditions.usesLessCellularData))
        }
        coordinator.updateConditions { $0.usesLessCellularData = true }
        #expect(coordinator.prefetchPolicy == .reduced)
        #expect(coordinator.fillSlots.limit == 0)
        #expect(recorder.signals.count == 1)
        coordinator.handle(.network(.wifi, isConstrained: false, isExpensive: false))
        #expect(coordinator.prefetchPolicy == .full, "a network change keeps the user's choice and Wi-Fi ignores it")
        #expect(coordinator.conditions.usesLessCellularData)
        observation.cancel()
    }

    @Test func theInitialConditionsSizeTheFillSlots() {
        let constrained = makeCoordinator(conditions: CacheConditions(isNetworkConstrained: true))
        #expect(constrained.fillSlots.limit == 0)
        #expect(makeCoordinator().fillSlots.limit == PrefetchPolicy.full.maxConcurrentSpeculativeFills)
    }

    @Test func anUnderBufferedVideoPausesSpeculativeFills() {
        let coordinator = makeCoordinator()
        coordinator.setPlaybackUnderBuffered(true)
        #expect(coordinator.fillSlots.isPaused)
        coordinator.setPlaybackUnderBuffered(false)
        #expect(!coordinator.fillSlots.isPaused)
    }
}


/// A disk cache that records each call the coordinator makes, and on which
/// thread.
private final class RecordingDiskCache: ManagedCache {
    struct Call: Sendable {
        let name: String
        let onMainThread: Bool
    }

    private let recorded = Mutex<[Call]>([])
    var calls: [Call] { recorded.withLock { $0 } }

    let namespace = CacheNamespace("recorded", category: .images, scope: .public)
    let budget = CacheBudget.disk(DiskBudget(pool: .images))
    var usage: CacheUsage { CacheUsage() }

    private func record(_ name: String) {
        let call = Call(name: name, onMainThread: Thread.isMainThread)
        recorded.withLock { $0.append(call) }
    }

    func setLimits(_ limits: CacheLimits) { record("setLimits") }
    func trim(_ depth: TrimDepth) { record("trim") }
    func removeAll() { record("removeAll") }
    func flush() { record("flush") }
}

private final class FlagBox: Sendable {
    private let flag = Mutex(false)
    var value: Bool { flag.withLock { $0 } }
    func set() { flag.withLock { $0 = true } }
}
