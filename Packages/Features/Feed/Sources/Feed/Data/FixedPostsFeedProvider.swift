import CoreModels
import FeedInterface
import Foundation

/// A `FeedProviding` whose "first page" is a fixed, ordered set of post ids —
/// the backing store for a snap feed opened from a Maps pin or cluster, rather
/// than the following timeline.
///
/// It reuses the real repository's single-post hydration (`loadPost`, which pulls
/// the post + author + like count off post.v1/profile.v1/counter.v1), so the map
/// feed shows genuine image/video media — not the Radar thumbnail — and inherits
/// every feed behaviour unchanged. With no continuation the set is exactly the
/// tapped posts; with one, the feed pages on into the source's next posts as
/// the viewer nears its end (#638).
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
    /// The source's next posts after a given one — see `SnapFeedContinuation`.
    private var continuation: SnapFeedContinuation?
    /// The last post served, where the continuation picks up.
    private var lastServed: PostID?
    /// The token a page hands back while the source may have more. Opaque to
    /// the feed; this provider keeps its own place (`lastServed`).
    static let continuationToken = "continue"
    /// Continuation steps whose posts ALL fail to hydrate, walked through in a
    /// row: such a page brings no row to come on screen and ask again.
    static let maxEmptySteps = 5
    /// Whether `ids` is everything the source has — a map marker's or a
    /// cluster's posts — so the first page is also the last (#628). Only
    /// meaningful without a continuation; with one, the continuation's own
    /// `nil` says when the end is reached.
    private var isCompleteSet: Bool

    init(
        base: any FeedProviding, ids: [PostID], continuation: SnapFeedContinuation? = nil,
        isCompleteSet: Bool = false
    ) {
        self.base = base
        self.ids = ids
        self.continuation = continuation
        self.isCompleteSet = isCompleteSet
    }

    /// Aims this provider at a different set. The next `loadFirstPage` serves
    /// it; nothing is cached here, so there is nothing else to invalidate. A
    /// re-aimed window is a whole set: whatever followed the old one does not
    /// follow this one.
    func repoint(to ids: [PostID]) {
        self.ids = ids
        continuation = nil
        lastServed = nil
        // A re-aimed window is somebody's window, not a whole set.
        isCompleteSet = false
    }

    func cachedFirstPage() async -> [FeedEntry]? { nil }

    /// Forwarded: the pre-push seed peeks THROUGH this provider at the real
    /// repository's warmed cache (the pins prewarmed it).
    nonisolated func peekPost(_ id: PostID) -> FeedEntry? { base.peekPost(id) }

    func loadFirstPage() async throws -> FeedPage {
        lastServed = ids.last
        let entries = await hydrate(ids)
        return FeedPage(
            entries: entries,
            nextPageToken: continuation == nil ? nil : Self.continuationToken,
            isCold: false,
            // A window with no continuation is the end only when it is the
            // whole set; otherwise its last post may be the middle of one.
            isEndOfSource: continuation == nil && isCompleteSet
        )
    }

    /// The source's next posts, hydrated (#638).
    ///
    /// ⚠️ An EMPTY step throws: the source had nothing right now (a failed
    /// page), and a throw is what keeps the feed's token, so its next approach
    /// asks again. Only `nil` — the source has no more — ends the feed.
    func loadPage(afterToken token: String) async throws -> FeedPage {
        guard let continuation, var after = lastServed else {
            return FeedPage(entries: [], nextPageToken: nil, isCold: false)
        }
        for _ in 0..<Self.maxEmptySteps {
            guard let next = await continuation(after) else {
                // The source said so: nothing follows (#628).
                return FeedPage(entries: [], nextPageToken: nil, isCold: false, isEndOfSource: true)
            }
            guard let last = next.last else { throw FeedContinuationError.nothingYet }
            after = last
            lastServed = last
            let entries = await hydrate(next)
            if !entries.isEmpty {
                return FeedPage(entries: entries, nextPageToken: Self.continuationToken, isCold: false)
            }
        }
        throw FeedContinuationError.nothingYet
    }

    /// Hydrates concurrently, preserving the given order. A post that fails
    /// to hydrate (deleted, expired) is dropped rather than failing the whole
    /// set — one missing pin must not blank the feed.
    private func hydrate(_ ids: [PostID]) async -> [FeedEntry] {
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
        return hydrated.sorted { $0.0 < $1.0 }.map(\.1)
    }

    func loadPost(_ id: PostID) async throws -> FeedEntry {
        try await base.loadPost(id)
    }

    /// Forwarded, like the peek: the post is held where every read looks.
    func remember(_ entry: FeedEntry) async {
        await base.remember(entry)
    }
}

/// The source had no posts to give right now — a failed page. The feed keeps
/// its place and asks again on its next approach.
enum FeedContinuationError: Error {
    case nothingYet
}
