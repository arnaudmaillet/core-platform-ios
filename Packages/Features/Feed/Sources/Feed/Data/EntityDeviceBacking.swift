import CoreModels
import EntityStore
import Foundation

/// The `EntityStore`'s device half (#896, #893): the posts in memory are
/// rebuilt from the LocalStore at a cold start, and a delete reaches the
/// device's copy too.
///
/// - **Rebuilt as copies.** `restore()` reads the posts the feed's lists
///   stored (`FeedLocalCache.storedPosts`), most recently used first, and
///   writes them as `.ifUnknown` copies in the `speculative` tier. A feed, a
///   grid or a profile restored from the device then draws the same entity —
///   one post, one count — whichever of them restores first, and a fresher
///   answer (a network page, a like, a realtime tick) is never replaced by the
///   device's older one. A post deleted this session stays out
///   (`EntityStore.isDeleted`).
/// - **Content only.** The viewer's facts — where they stand with a person,
///   what they saved — are not rebuilt from here: they stay in the store's
///   viewer-scoped namespaces, filled by the screens that ask and wiped on a
///   viewer change. The LocalStore holds one viewer's rows and reads nothing
///   for anyone else (`LocalStore.admitsRead`), so a rebuild for someone else
///   finds nothing either.
/// - **Deletes go through.** A post deleted anywhere leaves the device's lists
///   (`FeedLocalCache.forgetPosts`), so the next cold start does not open on it
///   before the network has answered.
public final class EntityDeviceBacking: Sendable {
    /// Posts rebuilt at most: under the store's speculative share (a fifth of
    /// its 2,000), so a rebuild never evicts itself. The device can hold far
    /// more (its budget is bytes); the most recently used are the ones a cold
    /// start shows.
    public static let restoreLimit = 300

    private let entities: EntityStore
    private let cache: FeedLocalCache
    private let observation: EntityObservation
    /// The device writes, in order, off the main thread.
    private static let queue = DispatchQueue(label: "cn.wynn.entity-device-backing", qos: .utility)

    public init(entities: EntityStore, cache: FeedLocalCache) {
        self.entities = entities
        self.cache = cache
        observation = entities.observePosts { [weak entities] change in
            // `.everything` is a viewer change wiping the viewer's facts:
            // nothing was deleted.
            guard let entities, case .some(let ids) = change else { return }
            let deleted = ids.filter(entities.isDeleted)
            guard !deleted.isEmpty else { return }
            Self.queue.async { cache.forgetPosts(deleted) }
        }
    }

    /// Rebuilds the posts the device holds into the store. It reads the
    /// file: call it off the main thread.
    public func restore(limit: Int = EntityDeviceBacking.restoreLimit) {
        let stored = cache.storedPosts(limit: limit)
        guard !stored.isEmpty else { return }
        // Least recently used first, so the most recently used are the
        // youngest of their tier: the last a trim would take.
        let ordered = Array(stored.reversed())
        entities.upsert(ordered.map(\.entry), tier: .speculative, counts: .ifUnknown)
        var comments: [PostID: PostCounts] = [:]
        for post in ordered {
            guard let count = post.commentCount else { continue }
            comments[post.entry.post.id] = PostCounts(comments: count)
        }
        entities.mergeCounts(comments, tier: .speculative, freshness: .ifUnknown)
    }

    /// Waits for every device write queued so far. Tests only.
    func waitForPendingWrites() {
        Self.queue.sync {}
    }
}
