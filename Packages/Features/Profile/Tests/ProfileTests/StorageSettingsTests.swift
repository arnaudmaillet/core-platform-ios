import CacheKit
import CoreStorage
import Foundation
import Testing
import UIKit
@testable import Profile

/// Settings → Storage (#899): usage and a clear per category through the
/// coordinator, the storage limit, and Use Less Cellular Data.
@MainActor
final class StorageSettingsTests {
    private let root: URL
    private let suite = "StorageSettingsTests-\(UUID().uuidString)"
    private let defaults: UserDefaults

    init() throws {
        root = FileManager.default.temporaryDirectory.appending(path: "storage-settings-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defaults = try #require(UserDefaults(suiteName: suite))
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
        UserDefaults().removePersistentDomain(forName: suite)
    }

    private static let device = CacheDevice(
        physicalMemory: { 4 << 30 }, availableDiskCapacity: { 100 * Int64(CacheBytes.gigabyte) }
    )

    private func makeCoordinator(conditions: CacheConditions = CacheConditions()) -> CacheCoordinator {
        CacheCoordinator(device: Self.device, storageLimit: .automatic, conditions: conditions)
    }

    private func disk(_ name: String, _ category: CacheCategory, pool: DiskPool) throws -> DiskStore {
        try DiskStore(
            namespace: CacheNamespace(name, category: category, scope: .public, priorityClass: .standard),
            budget: DiskBudget(pool: pool), root: root
        )
    }

    private func memory(_ name: String, _ category: CacheCategory) -> MemoryCache<String, String> {
        MemoryCache(
            namespace: CacheNamespace(name, category: category, scope: .public, priorityClass: .standard),
            budget: .fixed(bytes: 10_000)
        )
    }

    /// One namespace per category and medium, each holding a known size.
    private func populated() throws -> (CacheCoordinator, [any ManagedCache]) {
        let coordinator = makeCoordinator()
        let imagesMemory = memory("t.images.decoded", .images)
        let images = try disk("t.images", .images, pool: .images)
        let videos = try disk("t.videos", .videos, pool: .video)
        let messages = memory("t.messages", .messages)
        let other = try disk("t.pages", .other, pool: .localStore)
        let caches: [any ManagedCache] = [imagesMemory, images, videos, messages, other]
        for cache in caches { coordinator.register(cache) }
        imagesMemory.insert("i", for: "i", cost: 400)
        _ = try images.write(Data(count: 1_000), for: "i")
        _ = try videos.write(Data(count: 3_000), for: "v")
        messages.insert("m", for: "m", cost: 70)
        _ = try other.write(Data(count: 500), for: "p")
        return (coordinator, caches)
    }

    // MARK: - Usage

    @Test func sizesShownMatchTheCoordinatorsReport() async throws {
        let (coordinator, caches) = try populated()
        let model = StorageSettingsModel(
            inventory: MediaCacheInventory(locations: { [] }, urlCache: nil, coordinator: coordinator),
            coordinator: coordinator, defaults: defaults
        )
        await model.refresh()

        let shown = try #require(model.report)
        let truth = coordinator.usage()
        for category in StorageSettingsModel.categories {
            #expect(shown.bytes(in: category) == Int64(truth.bytes(in: category)), "\(category)")
        }
        #expect(shown.bytes(in: .images) == 1_400, "memory included")
        #expect(shown.bytes(in: .messages) == 70)
        #expect(shown.total == Int64(truth.totalBytes()))
        #expect(shown.limitedDiskBytes == Int64(truth.totalBytes(medium: .disk)))
        withExtendedLifetime(caches) {}
    }

    /// The caches no namespace holds yet are named by the inventory and land
    /// in their category: the synthesised clips under Videos, the shared HTTP
    /// cache under Other. They are not under the storage limit.
    @Test func cachesOutsideTheCoordinatorCountInTheirCategory() throws {
        let clip = root.appending(path: "fixture-v2-1.mp4")
        try Data(count: 2_000).write(to: clip)
        let inventory = MediaCacheInventory(locations: { [clip] }, urlCache: nil, indexedBytes: { 300 })

        let report = inventory.report()
        #expect(report.bytes(in: .videos) == 2_000)
        #expect(report.bytes(in: .other) == 300)
        #expect(report.limitedDiskBytes == 0)
        inventory.clear(.other)
        #expect(FileManager.default.fileExists(atPath: clip.path), "clearing Other leaves the videos")
        inventory.clear(.videos)
        #expect(!FileManager.default.fileExists(atPath: clip.path))
    }

    // MARK: - Clear

    @Test func clearingOneCategoryEmptiesItsMemoryAndDiskAndNothingElse() async throws {
        let (coordinator, caches) = try populated()
        let model = StorageSettingsModel(
            inventory: MediaCacheInventory(locations: { [] }, urlCache: nil, coordinator: coordinator),
            coordinator: coordinator, defaults: defaults
        )
        await model.clear(.images)

        let report = try #require(model.report)
        #expect(report.bytes(in: .images) == 0, "decoded memory and disk both emptied")
        #expect(report.bytes(in: .videos) == 3_000)
        #expect(report.bytes(in: .messages) == 70)
        #expect(report.bytes(in: .other) == 500)

        await model.clear(nil)
        #expect(model.report?.total == 0)
        withExtendedLifetime(caches) {}
    }

    /// Drafts, the like outbox, preferences and the session are not caches:
    /// a Clear All never reaches them.
    @Test func clearAllLeavesDraftsTheOutboxAndPreferences() async throws {
        let (coordinator, caches) = try populated()
        let draftsName = "storage-settings-drafts-\(UUID().uuidString)"
        let drafts = PostDraftStore(name: draftsName)
        let draft = try #require(drafts.save("half a post"))
        defer { drafts.delete(draft.id) }
        let outbox = LikeOutbox(defaults: defaults)
        let target = LikeOutbox.Target.post("p1")
        outbox.record(points: 3, on: target)
        let playback = MediaPlaybackPreferencesStore(defaults: defaults)
        playback.update { $0.autoplay = .never }
        let clip = root.appending(path: "clip.mp4")
        try Data(count: 10).write(to: clip)

        let model = StorageSettingsModel(
            inventory: MediaCacheInventory(locations: { [clip] }, urlCache: nil, coordinator: coordinator),
            coordinator: coordinator, playback: playback, defaults: defaults
        )
        await model.clear(nil)

        #expect(model.report?.total == 0)
        #expect(PostDraftStore(name: draftsName).draft(draft.id)?.text == "half a post")
        #expect(outbox.pendingPoints(on: target) == 3)
        #expect(playback.preferences.autoplay == .never)
        withExtendedLifetime(caches) {}
    }

    // MARK: - Limit

    /// A file of `megabytes` that takes no disk space (sparse), so a test can
    /// fill a pool to a gigabyte.
    private func sparseFile(megabytes: Int) throws -> URL {
        let url = root.appending(path: "sparse-\(UUID().uuidString)")
        #expect(FileManager.default.createFile(atPath: url.path, contents: nil))
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: UInt64(megabytes * CacheBytes.megabyte))
        try handle.close()
        return url
    }

    /// Choosing 0.5 GB with 1 GB cached trims to 0.5 GB at once, speculative
    /// entries first and then the least recently used; the choice is kept.
    @Test func choosingHalfAGigabyteWithAGigabyteCachedTrimsAtOnce() async throws {
        let coordinator = makeCoordinator()
        let video = try disk("t.video", .videos, pool: .video)
        let images = try disk("t.images", .images, pool: .images)
        let pages = try disk("t.pages", .other, pool: .localStore)
        for cache in [video, images, pages] { coordinator.register(cache) }
        let model = StorageSettingsModel(
            inventory: MediaCacheInventory(locations: { [] }, urlCache: nil, coordinator: coordinator),
            coordinator: coordinator, defaults: defaults
        )
        await model.choose(.twoGigabytes)
        #expect(try video.moveItem(at: sparseFile(megabytes: 250), for: "old", tier: .recent))
        #expect(try video.moveItem(at: sparseFile(megabytes: 250), for: "newer", tier: .recent))
        #expect(try video.moveItem(at: sparseFile(megabytes: 100), for: "ahead", tier: .speculative))
        #expect(try images.moveItem(at: sparseFile(megabytes: 300), for: "photo", tier: .recent))
        #expect(try pages.moveItem(at: sparseFile(megabytes: 100), for: "page", tier: .recent))
        await model.refresh()
        #expect(model.report?.limitedDiskBytes == Int64(1_000 * CacheBytes.megabyte))

        await model.choose(.halfGigabyte)

        #expect(coordinator.storageLimit == .halfGigabyte)
        #expect(CacheStoragePreference.load(from: defaults) == .halfGigabyte, "kept for the next launch")
        let report = try #require(model.report)
        #expect(report.limitedDiskBytes <= Int64(CacheBytes.gigabyte / 2))
        #expect(model.limitBytes <= Int64(CacheBytes.gigabyte / 2))
        #expect(!video.contains("ahead"), "speculative goes first, though the newest")
        #expect(!video.contains("old"), "then the least recently used")
        #expect(video.contains("newer"))
    }

    @Test func automaticIsTheDefaultAndShowsThePoolsTotal() {
        let model = StorageSettingsModel(
            inventory: MediaCacheInventory(locations: { [] }, urlCache: nil),
            coordinator: makeCoordinator(), defaults: defaults
        )
        #expect(model.limit == .automatic)
        #expect(model.limitBytes == Int64(DiskPoolBudgets(limit: .automatic, pressure: .normal).total))
    }

    // MARK: - Cellular

    @Test func useLessCellularDataReducesCellularPrefetchAndIsKept() {
        let coordinator = makeCoordinator(conditions: CacheConditions(network: .cellular))
        let playback = MediaPlaybackPreferencesStore(defaults: defaults)
        let model = StorageSettingsModel(
            inventory: MediaCacheInventory(locations: { [] }, urlCache: nil),
            coordinator: coordinator, playback: playback, defaults: defaults
        )
        #expect(!model.usesLessCellularData)
        #expect(coordinator.prefetchPolicy == .cellular)

        model.setUsesLessCellularData(true)

        #expect(coordinator.prefetchPolicy == .reduced)
        #expect(playback.preferences.dataSaver, "the same preference caps the stream quality")
        #expect(StorageSettingsModel(
            inventory: MediaCacheInventory(locations: { [] }, urlCache: nil),
            coordinator: nil, playback: MediaPlaybackPreferencesStore(defaults: defaults), defaults: defaults
        ).usesLessCellularData, "kept for the next launch")

        model.setUsesLessCellularData(false)
        #expect(coordinator.prefetchPolicy == .cellular)
    }

    // MARK: - Screen

    @Test func theScreenListsEveryCategoryTheLimitsAndTheToggle() {
        #expect(StorageSettingsViewController.items(in: .usage) == [
            .category(.images), .category(.videos), .category(.sounds), .category(.messages), .category(.other), .total, .clearAll
        ])
        #expect(StorageSettingsViewController.items(in: .limit) == [
            .inUse, .limit(.automatic), .limit(.halfGigabyte), .limit(.oneGigabyte), .limit(.twoGigabytes)
        ])
        #expect(StorageSettingsViewController.items(in: .cellular) == [.lessCellularData])
        // Sizes follow the device's number format ("0.5 GB", "0,5 GB").
        let titles = CacheStorageLimit.choices.map(StorageSettingsViewController.title)
        #expect(titles.count == 4 && titles[0] == "Automatic" && titles[2] == "1 GB" && titles[3] == "2 GB")
        #expect(["0.5 GB", "0,5 GB"].contains(titles[1]), "\(titles[1])")

        let screen = StorageSettingsViewController(model: StorageSettingsModel(
            inventory: MediaCacheInventory(locations: { [] }, urlCache: nil),
            coordinator: makeCoordinator(), defaults: defaults
        ))
        screen.loadViewIfNeeded()
        #expect(screen.title == "Storage")
    }
}
