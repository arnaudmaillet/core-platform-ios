import CacheKit
import Foundation
import MediaCore
import MediaPlayback
import Synchronization
import Testing
import UIKit
@testable import Profile

/// Settings → Storage (#409, #899): the caches are measured and cleared by
/// what the inventory OWNS, never by directory.
struct MediaCacheInventoryTests {
    private func scratch() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("cache-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    @Test func measuresAndClearsOnlyItsOwnLocations() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let clip = root.appendingPathComponent("fixture-v2-1.mp4")
        let emotes = root.appendingPathComponent("EmoteKit", isDirectory: true)
        let draft = root.appendingPathComponent("UploadCaptures-draft.mov")
        try Data(count: 1_000).write(to: clip)
        try FileManager.default.createDirectory(at: emotes, withIntermediateDirectories: true)
        try Data(count: 500).write(to: emotes.appendingPathComponent("sheet.png"))
        try Data(count: 2_000).write(to: draft)

        let inventory = MediaCacheInventory(locations: { [clip, emotes] }, urlCache: nil)
        #expect(inventory.report().total == 1_500)
        inventory.clear(nil)
        #expect(inventory.report().total == 0)
        #expect(FileManager.default.fileExists(atPath: draft.path), "a file it doesn't own must survive")
    }

    /// An indexed cache (the UI assets namespace) is measured and cleared
    /// through itself, never by deleting its folder.
    @Test func indexedCachesAreMeasuredAndClearedThroughThemselves() {
        let held = Mutex<Int64>(700)
        let inventory = MediaCacheInventory(
            locations: { [] }, urlCache: nil,
            indexedBytes: { held.withLock { $0 } },
            clearIndexed: { held.withLock { $0 = 0 } }
        )
        #expect(inventory.report().bytes(in: .other) == 700)
        inventory.clear(.other)
        #expect(inventory.report().total == 0)
    }

    @Test func missingLocationsCountForNothing() {
        let inventory = MediaCacheInventory(locations: { [URL(fileURLWithPath: "/nonexistent/\(UUID().uuidString)")] }, urlCache: nil)
        #expect(inventory.report().total == 0)
        inventory.clear(nil)
    }

    /// Since #894 the images live in the pipeline's CacheKit stores, not in
    /// `URLCache.shared`: Storage counts every image store and a clear empties
    /// them, memory included, so the next request goes to the network.
    @Test func imagesAreMeasuredAndClearedThroughTheCoordinator() async throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let coordinator = CacheCoordinator(device: CacheDevice(
            physicalMemory: { 4 << 30 }, availableDiskCapacity: { 100 * Int64(CacheBytes.gigabyte) }
        ))
        let fetcher = CountingImageFetcher()
        let pipeline = ImagePipeline(fetcher: fetcher, disk: .folder(root), coordinator: coordinator)
        await pipeline.waitUntilDiskIsOpen()
        // A UI assets namespace (`.other`): left to its own category's clear.
        let assets = try DiskStore(
            namespace: CacheNamespace("ui.assets.test", category: .other, scope: .public, priorityClass: .persistent),
            budget: .reserved(CacheBytes.megabyte, in: .images), root: root
        )
        _ = try assets.write(Data(count: 4_000), for: "sheet", tier: .recent)
        coordinator.register(assets)

        let photo = try #require(URL(string: "https://cdn.example.com/photo/1.png"))
        let avatar = try #require(URL(string: "https://cdn.example.com/avatar/1.png"))
        let signed = try #require(URL(string: "https://cdn.example.com/private/1.png?X-Amz-Signature=abc&X-Amz-Expires=60"))
        _ = try await pipeline.image(for: photo)
        _ = try await pipeline.image(for: avatar, size: .avatar)
        _ = try await pipeline.image(for: signed)

        let before = coordinator.usage()
        for name in ["images", "images.small", "images.signed"] {
            #expect((before.usage(of: name, medium: .disk)?.bytes ?? 0) > 0, "\(name) holds an image")
        }
        let inventory = MediaCacheInventory(locations: { [] }, urlCache: nil, coordinator: coordinator)
        #expect(inventory.report().bytes(in: .images) == Int64(before.bytes(in: .images)), "every image store and decoded memory")

        inventory.clear(.images)

        let after = coordinator.usage()
        #expect(after.bytes(in: .images) == 0, "disk and decoded memory both emptied")
        #expect(inventory.report().bytes(in: .images) == 0)
        #expect(!pipeline.isDecoded(photo) && !pipeline.isOnDisk(photo))
        #expect(after.usage(of: "ui.assets.test", medium: .disk)?.bytes == before.usage(of: "ui.assets.test", medium: .disk)?.bytes,
                "another category is left to its own clear")
        _ = try await pipeline.image(for: photo)
        #expect(fetcher.fetchCount(for: photo) == 2, "the next request goes to the network")
    }

    /// The video byte cache (#895) is counted and cleared as Videos: its two
    /// namespaces are in the `.videos` category.
    @Test func videoRangesAreMeasuredAndClearedThroughTheCoordinator() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let coordinator = CacheCoordinator(device: CacheDevice(
            physicalMemory: { 4 << 30 }, availableDiskCapacity: { 100 * Int64(CacheBytes.gigabyte) }
        ))
        for namespace in [VideoByteCache.publicNamespace, VideoByteCache.signedNamespace] {
            let store = try DiskStore(namespace: namespace, budget: DiskBudget(pool: .video), root: root)
            _ = try store.write(Data(count: 3_000), for: "https://cdn.example.com/v.mp4#0", tier: .retained)
            coordinator.register(store)
        }
        let inventory = MediaCacheInventory(locations: { [] }, urlCache: nil, coordinator: coordinator)
        #expect(inventory.report().bytes(in: .videos) == 6_000)

        inventory.clear(.videos)

        #expect(coordinator.usage().bytes(in: .videos) == 0)
        #expect(inventory.report().bytes(in: .videos) == 0)
    }

    /// Songs and sound previews (#1068) share the video byte cache's loader,
    /// not its namespaces: the inventory counts them as Music & Sounds, never
    /// as Videos, and each category's clear removes its own bytes only.
    @Test func songsAreCountedAndClearedAsSoundsNotVideos() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let coordinator = CacheCoordinator(device: CacheDevice(
            physicalMemory: { 4 << 30 }, availableDiskCapacity: { 100 * Int64(CacheBytes.gigabyte) }
        ))
        func store(_ namespace: CacheNamespace, bytes: Int) throws -> DiskStore {
            let store = try DiskStore(namespace: namespace, budget: DiskBudget(pool: .video), root: root)
            _ = try store.write(Data(count: bytes), for: "https://cdn.example.com/\(namespace.name)#0", tier: .retained)
            coordinator.register(store)
            return store
        }
        let clips = try store(VideoByteCache.publicNamespace, bytes: 3_000)
        let signedClips = try store(VideoByteCache.signedNamespace, bytes: 1_000)
        let songs = try store(VideoByteCache.soundNamespace, bytes: 700)
        let signedSongs = try store(VideoByteCache.signedSoundNamespace, bytes: 300)
        let inventory = MediaCacheInventory(locations: { [] }, urlCache: nil, coordinator: coordinator)

        let report = inventory.report()
        #expect(report.bytes(in: .videos) == 4_000, "a song counted as Videos")
        #expect(report.bytes(in: .sounds) == 1_000)

        inventory.clear(.videos)
        #expect(inventory.report().bytes(in: .videos) == 0)
        #expect(inventory.report().bytes(in: .sounds) == 1_000, "Clear Videos removed the songs")

        _ = try clips.write(Data(count: 3_000), for: "https://cdn.example.com/again#0", tier: .retained)
        inventory.clear(.sounds)
        #expect(inventory.report().bytes(in: .sounds) == 0)
        #expect(inventory.report().bytes(in: .videos) == 3_000, "Clear Music & Sounds removed a clip")
        withExtendedLifetime([clips, signedClips, songs, signedSongs]) {}
    }
}

/// Serves a small PNG for any URL and counts fetches per URL.
private final class CountingImageFetcher: ImageFetching {
    private let fetches = Mutex<[URL: Int]>([:])

    func fetchCount(for url: URL) -> Int { fetches.withLock { $0[url] ?? 0 } }

    func fetchImageData(for url: URL) async throws -> Data {
        fetches.withLock { $0[url, default: 0] += 1 }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: 64, height: 64), format: format).pngData { context in
            UIColor.orange.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
        }
    }
}
