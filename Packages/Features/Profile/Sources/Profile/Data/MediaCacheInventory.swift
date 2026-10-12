import CacheKit
import EmoteKit
import Foundation
import MediaPlayback

/// The rebuildable media caches on this device, measured and cleared from
/// Settings → App Preferences (#409): downloaded or synthesised video clips
/// (`VideoSourceCache`), baked emote sheets (`EmoteCache`, the UI assets
/// disk namespace of #971), the shared HTTP cache, and every image the
/// pipeline keeps (#894), through the app's `CacheCoordinator`.
///
/// Deliberately a list of what is OWNED, never "the caches directory": the
/// temporary directory also holds Upload's captures and soundtracks in
/// flight, and clearing those would break a post being made.
struct MediaCacheInventory: Sendable {
    /// Files and directories to measure and remove.
    var locations: @Sendable () -> [URL]
    var urlCache: URLCache?
    /// Bytes of the caches that keep an index (CacheKit namespaces), measured
    /// by the cache itself.
    var indexedBytes: @Sendable () -> Int64 = { 0 }
    /// Clears those caches THROUGH their index: deleting their folder behind
    /// their back would leave an index naming files that are gone.
    var clearIndexed: @Sendable () -> Void = {}
    /// The app's cache coordinator, which measures and clears the namespaces
    /// of `coordinatedCategories`. Since #894 images live in its disk stores (`images`, `images.small`,
    /// `images.signed`) and decoded memory, not in `URLCache.shared`: a clear
    /// that skipped them left up to the whole images pool behind.
    var coordinator: CacheCoordinator?

    /// The categories this inventory measures and clears through `coordinator`.
    /// UI assets (`.other`) stay with `indexedBytes`/`clearIndexed`, and the
    /// LocalStore (#893) is not a media cache.
    static let coordinatedCategories: [CacheCategory] = [.images]

    static func standard(coordinator: CacheCoordinator? = nil) -> MediaCacheInventory {
        MediaCacheInventory(
            locations: { VideoSourceCache.files() },
            urlCache: .shared,
            indexedBytes: { EmoteCache.diskBytes() },
            clearIndexed: { EmoteCache.removeAll() },
            coordinator: coordinator
        )
    }

    /// Bytes on disk. Walks the file system: call it off the main thread.
    func size() -> Int64 {
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
        return total + indexedBytes() + coordinatedBytes() + Int64(urlCache?.currentDiskUsage ?? 0)
    }

    /// Bytes on disk of the coordinated categories, as their stores report.
    private func coordinatedBytes() -> Int64 {
        guard let coordinator else { return 0 }
        let report = coordinator.usage()
        return Self.coordinatedCategories.reduce(0) { $0 + Int64(report.bytes(in: $1, medium: .disk)) }
    }

    /// Removes every owned cache. Anything in use is rebuilt on its next read.
    func clear() {
        for url in locations() {
            try? FileManager.default.removeItem(at: url)
        }
        clearIndexed()
        // Memory and disk together, so a cleared image is fetched again rather
        // than still served decoded until the next launch. A leased entry (on
        // screen) stops being served at once; its bytes go when the lease ends.
        for category in Self.coordinatedCategories {
            coordinator?.trim(.clear(category))
        }
        urlCache?.removeAllCachedResponses()
    }

    static func formatted(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
