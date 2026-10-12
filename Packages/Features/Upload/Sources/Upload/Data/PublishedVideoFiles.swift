import CacheKit
import Foundation
import MediaPlayback
import Synchronization

/// The clips the viewer just published, kept for their own post's playback
/// (#898).
///
/// The entry a publish hands back plays the exported file itself, so the
/// author's clip starts at once, before any fetch (`PostComposer`). That file
/// used to stay in the temporary directory for good. Now, once the post is
/// out, it is MOVED here: a disk namespace of the device cache, so it counts
/// against the storage limit, shows in Settings → Storage (Videos), is
/// evicted oldest first, and goes with the viewer on a logout or a profile
/// switch.
///
/// - **Namespace** `video.published`: Videos, viewer-scoped (the viewer's own
///   content until the server's copy replaces it), `standard` class.
/// - **Budget:** 100 MB reserved in the video pool, entries `retained`. Low
///   disk shrinks the shared video namespaces first; under 1 GB free the pool
///   is off, the clip is refused and the post plays from its delivery URL.
///
/// The store opens on the first clip kept, on the composer's thread (never
/// the main one), and joins the coordinator the app attached, then or later.
public final class PublishedVideoFiles: Sendable {
    /// The app's: the default of every `PostComposer`.
    public static let shared = PublishedVideoFiles()

    public static let namespace = CacheNamespace("video.published", category: .videos, scope: .viewer, priorityClass: .standard)
    public static let reservedBytes = 100 * CacheBytes.megabyte
    public static let diskBudget = DiskBudget.reserved(reservedBytes, in: .video)

    private struct State {
        var store: DiskStore?
        var opened = false
        var coordinator: CacheCoordinator?
    }

    private let root: URL?
    private let state = Mutex(State())

    /// - Parameter root: where the namespace's folder goes; the app's
    ///   `Caches` by default. Open ONE instance per folder per process
    ///   (`DiskStore`): the app uses `shared`, a test its own folder.
    public init(root: URL? = nil) {
        self.root = root
    }

    /// Registers the store with `coordinator` (budgets, the viewer's wipe,
    /// Settings), now if it is open, or when it opens.
    public func attach(to coordinator: CacheCoordinator) {
        let store = state.withLock { state -> DiskStore? in
            state.coordinator = coordinator
            return state.store
        }
        if let store { coordinator.register(store) }
    }

    /// Moves `exported`'s file into the store under `remoteURL`, as the
    /// viewer's own content. Returns where the clip now is; nil when it cannot
    /// be kept (no room, or the store cannot open): the file is then deleted
    /// with `exported`'s last copy.
    func keep(_ exported: ExportedVideo, for remoteURL: URL) -> URL? {
        guard let store = openedStore() else { return nil }
        let key = CacheKey.media(remoteURL)
        let kept = withExtendedLifetime(exported) {
            (try? store.moveItem(at: exported.fileURL, for: key, tier: .retained)) ?? false
        }
        return kept ? store.fileURL(for: key) : nil
    }

    /// The store's folder, for tests.
    var directory: URL? { openedStore()?.directory }

    private func openedStore() -> DiskStore? {
        let opening = state.withLock { state -> (store: DiskStore?, register: CacheCoordinator?) in
            if state.opened { return (state.store, nil) }
            state.opened = true
            // `.mp4` names: the player reads a file's type from its extension.
            state.store = try? DiskStore(
                namespace: Self.namespace, budget: Self.diskBudget, root: root,
                limits: CacheLimits(bytes: Self.reservedBytes, speculativeShare: CacheCoordinator.speculativeShare),
                fileExtension: "mp4"
            )
            return (state.store, state.coordinator)
        }
        if let store = opening.store, let coordinator = opening.register { coordinator.register(store) }
        return opening.store
    }
}
