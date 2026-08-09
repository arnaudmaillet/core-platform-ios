import CoreModels
import Foundation

/// A `FeedProviding` whose "first page" is a fixed, ordered set of post ids —
/// the backing store for a snap feed opened from a Maps pin or cluster, rather
/// than the following timeline.
///
/// It reuses the real repository's single-post hydration (`loadPost`, which pulls
/// the post + author + like count off post.v1/profile.v1/counter.v1), so the map
/// feed shows genuine image/video media — not the Radar thumbnail — and inherits
/// every feed behaviour unchanged. There is no pagination: the set is exactly the
/// tapped posts.
/// A fixed provider that can be re-aimed at a different window of posts.
///
/// The point is upstream of the data: a screen whose corpus can be replaced
/// does not have to be REBUILT to show a different set, and rebuilding the
/// snap feed is what makes a hero push expensive — a fresh controller means
/// fresh bar chrome, and iOS 26 materialises that chrome's glass inside the
/// push (see `ZoomFlightProfiler`).
protocol RepointableFeedProviding: FeedProviding {
    func repoint(to ids: [PostID]) async
}

actor FixedPostsFeedProvider: FeedProviding, RepointableFeedProviding {
    private let base: any FeedProviding
    private var ids: [PostID]

    init(base: any FeedProviding, ids: [PostID]) {
        self.base = base
        self.ids = ids
    }

    /// Aims this provider at a different set. The next `loadFirstPage` serves
    /// it; nothing is cached here, so there is nothing else to invalidate.
    func repoint(to ids: [PostID]) {
        self.ids = ids
    }

    func cachedFirstPage() async -> [FeedEntry]? { nil }

    func loadFirstPage() async throws -> FeedPage {
        // Hydrate concurrently, preserving the tapped order. A post that fails to
        // hydrate (deleted, expired) is dropped rather than failing the whole
        // set — one missing pin must not blank the feed.
        let base = base
        let hydrated = await withTaskGroup(of: (Int, FeedEntry)?.self) { group in
            for (index, id) in ids.enumerated() {
                group.addTask {
                    guard let entry = try? await base.loadPost(id) else { return nil }
                    return (index, entry)
                }
            }
            var collected: [(Int, FeedEntry)] = []
            for await result in group {
                if let result { collected.append(result) }
            }
            return collected
        }
        let entries = hydrated.sorted { $0.0 < $1.0 }.map(\.1)
        return FeedPage(entries: entries, nextPageToken: nil, isCold: false)
    }

    func loadPage(afterToken token: String) async throws -> FeedPage {
        FeedPage(entries: [], nextPageToken: nil, isCold: false)
    }

    func loadPost(_ id: PostID) async throws -> FeedEntry {
        try await base.loadPost(id)
    }
}
