import CacheKit
import Foundation

/// Voice messages' audio on disk, keyed by the media asset id (#2101):
/// a message played once plays again offline, and the sender's own take is
/// kept as its message's audio — never downloaded back.
///
/// Signed media (`CacheScope.signed`): only this viewer could fetch it, so a
/// logout or a switch of profile wipes it. Messages' category, in the
/// LocalStore's small pool: a minute of voice is about 240 KB.
public final class VoiceFileCache: Sendable {
    public static let namespace = CacheNamespace(
        "voice.messages", category: .messages, scope: .signed, priorityClass: .preferred
    )

    public let store: DiskStore

    public init(store: DiskStore) {
        self.store = store
    }

    /// Opens the namespace under `root` (the app's Caches by default). Once
    /// per folder per process (`DiskStore`).
    public static func open(root: URL? = nil) throws -> VoiceFileCache {
        VoiceFileCache(store: try DiskStore(
            namespace: namespace,
            budget: DiskBudget(pool: .localStore),
            root: root,
            fileExtension: "m4a"
        ))
    }

    /// The file for `assetID`, nil when it isn't on disk.
    public func fileURL(forAsset assetID: String) -> URL? {
        store.fileURL(for: assetID)
    }

    /// Keeps the file at `url` as `assetID`'s audio — MOVED in, not copied: a
    /// take or a download is the cache's from now on.
    @discardableResult
    public func keep(fileAt url: URL, forAsset assetID: String, tier: CacheTier = .recent) throws -> URL? {
        _ = try store.moveItem(at: url, for: assetID, tier: tier)
        return store.fileURL(for: assetID)
    }
}
