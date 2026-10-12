import EmoteKit
import Foundation
import MediaPlayback

/// The rebuildable media caches on this device, measured and cleared from
/// Settings → App Preferences (#409): downloaded or synthesised video clips
/// (`VideoSourceCache`), baked emote sheets (`EmoteCache`, the UI assets
/// disk namespace of #971) and the shared HTTP cache.
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

    static let standard = MediaCacheInventory(
        locations: { VideoSourceCache.files() },
        urlCache: .shared,
        indexedBytes: { EmoteCache.diskBytes() },
        clearIndexed: { EmoteCache.removeAll() }
    )

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
        return total + indexedBytes() + Int64(urlCache?.currentDiskUsage ?? 0)
    }

    /// Removes every owned cache. Anything in use is rebuilt on its next read.
    func clear() {
        for url in locations() {
            try? FileManager.default.removeItem(at: url)
        }
        clearIndexed()
        urlCache?.removeAllCachedResponses()
    }

    static func formatted(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
