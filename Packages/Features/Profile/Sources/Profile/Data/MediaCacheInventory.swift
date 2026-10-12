import CacheKit
import EmoteKit
import Foundation
import MediaPlayback

/// What Settings → Storage measures: each category's bytes, memory and disk.
struct StorageReport: Equatable, Sendable {
    /// Memory and disk bytes of each category: the coordinator's namespaces
    /// plus the caches the inventory names itself.
    var bytes: [CacheCategory: Int64]
    /// Bytes on disk of the coordinator's namespaces: what the storage limit
    /// caps.
    var limitedDiskBytes: Int64

        func bytes(in category: CacheCategory) -> Int64 { bytes[category] ?? 0 }
    var total: Int64 { bytes.values.reduce(0, +) }
}

/// The rebuildable caches on this device, measured and cleared per category
/// from Settings → Storage (#409, #899).
///
/// - **Through the coordinator:** every namespace registered with the app's
///   `CacheCoordinator`, memory and disk: images (#894), UI assets and the
///   LocalStore pages (`.other`, #971, #893), and video and messages as they
///   join it (#895, #897). Cleared with `trim(.clear(category))`: a leased
///   entry (on screen, an upload in flight) stops being served at once and
///   its bytes go when its lease ends.
/// - **Named here:** the synthesised video clips (`VideoSourceCache`, Videos)
///   and the shared HTTP cache (Other), which no namespace holds yet. Without
///   a coordinator, also the UI assets disk namespace (`indexedBytes`).
///
/// Deliberately a list of what is OWNED, never "the caches directory": the
/// temporary directory also holds Upload's captures and soundtracks in
/// flight, and drafts, the like outbox, preferences and the session live
/// elsewhere; none of them is a cache.
struct MediaCacheInventory: Sendable {
    /// Files and directories counted as Videos, measured and removed by path.
    var locations: @Sendable () -> [URL]
    /// Counted as Other.
    var urlCache: URLCache?
    /// Bytes of an indexed cache no coordinator holds (Other), measured by
    /// the cache itself.
    var indexedBytes: @Sendable () -> Int64 = { 0 }
    /// Clears it THROUGH its index: deleting its folder behind its back would
    /// leave an index naming files that are gone.
    var clearIndexed: @Sendable () -> Void = {}
    var coordinator: CacheCoordinator?

    /// The app's inventory. With a coordinator the UI assets namespace is one
    /// of its `.other` namespaces, so it is not named a second time.
    static func standard(coordinator: CacheCoordinator? = nil) -> MediaCacheInventory {
        var inventory = MediaCacheInventory(
            locations: { VideoSourceCache.files() },
            urlCache: .shared,
            coordinator: coordinator
        )
        if coordinator == nil {
            inventory.indexedBytes = { EmoteCache.diskBytes() }
            inventory.clearIndexed = { EmoteCache.removeAll() }
        }
        return inventory
    }

    /// Measures every category. Walks the file system: call it off the main
    /// thread.
    func report() -> StorageReport {
        var bytes = Dictionary(uniqueKeysWithValues: CacheCategory.allCases.map { ($0, Int64(0)) })
        var limited: Int64 = 0
        if let coordinator {
            let usage = coordinator.usage()
            for category in CacheCategory.allCases {
                bytes[category, default: 0] += Int64(usage.bytes(in: category))
            }
            limited = Int64(usage.totalBytes(medium: .disk))
        }
        bytes[.videos, default: 0] += filesBytes()
        bytes[.other, default: 0] += indexedBytes() + Int64(urlCache?.currentDiskUsage ?? 0)
        return StorageReport(bytes: bytes, limitedDiskBytes: limited)
    }

    /// Removes one category, or everything (`nil`), memory and disk together.
    /// Anything in use is rebuilt on its next read.
    func clear(_ category: CacheCategory?) {
        coordinator?.trim(.clear(category))
        if category == nil || category == .videos {
            for url in locations() {
                try? FileManager.default.removeItem(at: url)
            }
        }
        if category == nil || category == .other {
            clearIndexed()
            urlCache?.removeAllCachedResponses()
        }
    }

    private func filesBytes() -> Int64 {
        let fileManager = FileManager.default
        var total: Int64 = 0
        for url in locations() {
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else { continue }
            if isDirectory.boolValue {
                let enumerator = fileManager.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey])
                while let file = enumerator?.nextObject() as? URL {
                    total += Int64((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
                }
            } else {
                total += Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            }
        }
        return total
    }

    static func formatted(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
