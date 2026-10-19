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
    /// `continuation`: what follows the new window, nil for nothing (#1343).
    func repoint(to ids: [PostID], continuation: SnapFeedContinuation?) async
}

extension RepointableFeedProviding {
    /// A provider that cannot carry a continuation takes the window alone.
    func repoint(to ids: [PostID], continuation: SnapFeedContinuation?) async {
        await repoint(to: ids)
    }
}

/// The one kind of post a vertical feed pages through (#1421, the owner
/// 2026-10-19): opened on a media post (photo, video, carousel), media posts
/// only; opened on a text post, text posts only. Read off the OPENING post —
/// the screens a feed is opened from keep their mixed lists.
enum SnapFeedKindScope: Equatable, Sendable {
    case media, text

    /// A post with no attachment is a text post — `GalleryFilter.Format
    /// .short`'s rule; a carousel is media.
    init(_ entry: FeedEntry) {
        self = entry.post.attachments.isEmpty ? .text : .media
    }

    func admits(_ entry: FeedEntry) -> Bool { Self(entry) == self }
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
    /// Whether this is a vertical feed's provider, which keeps to its opening
    /// post's kind (#1421) — not a hydration helper (a place's or a search
    /// surface's posts, Discover's pages), which serves every id it is given.
    private let keepsToOpeningKind: Bool
    /// The kind this window keeps to: read off its first post once hydrated,
    /// and read again on every repoint, so a reused feed never keeps a kind
    /// that was another opening's. Nil: no scope (not kept, or the opening
    /// post did not hydrate — then nothing is filtered rather than everything).
    private(set) var scope: SnapFeedKindScope?
    /// A scoped page the source cut short is filled from the continuation up
    /// to this many posts, in at most `maxFillRounds` asks — text posts are
    /// rarer, and a page with one post on it reads as the end.
    static let scopedPageMinimum = 5
    static let maxFillRounds = 8

    init(
        base: any FeedProviding, ids: [PostID], continuation: SnapFeedContinuation? = nil,
        isCompleteSet: Bool = false, keepsToOpeningKind: Bool = false
    ) {
        self.base = base
        self.ids = ids
        self.continuation = continuation
        self.isCompleteSet = isCompleteSet
        self.keepsToOpeningKind = keepsToOpeningKind
    }

    /// Aims this provider at a different set. The next `loadFirstPage` serves
    /// it; nothing is cached here, so there is nothing else to invalidate. A
    /// re-aimed window is a whole set unless it brings its own continuation:
    /// whatever followed the old one does not follow this one.
    func repoint(to ids: [PostID], continuation: SnapFeedContinuation?) {
        self.ids = ids
        self.continuation = continuation
        lastServed = nil
        // Read again off the new opening post (`loadFirstPage`).
        scope = nil
        // A re-aimed window is somebody's window, not a whole set.
        isCompleteSet = false
    }

    /// A re-aimed window with nothing after it.
    func repoint(to ids: [PostID]) {
        repoint(to: ids, continuation: nil)
    }

    func cachedFirstPage() async -> [FeedEntry]? { nil }

    /// Forwarded: the pre-push seed peeks THROUGH this provider at the real
    /// repository's warmed cache (the pins prewarmed it).
    nonisolated func peekPost(_ id: PostID) -> FeedEntry? { base.peekPost(id) }

    func loadFirstPage() async throws -> FeedPage {
        lastServed = ids.last
        var entries = await hydrate(ids)
        var ended = false
        if keepsToOpeningKind {
            // The opening post is the window's first, and always its own kind.
            scope = ids.first.flatMap { first in entries.first { $0.post.id == first } }.map(SnapFeedKindScope.init)
            entries = kept(entries)
            // A short window is filled from what follows, so the feed does
            // not read "the end" while the source has more of this kind.
            if scope != nil, continuation != nil, entries.count < Self.scopedPageMinimum, let after = lastServed {
                let more = try? await followOn(after: after, wanting: Self.scopedPageMinimum - entries.count)
                entries += more?.entries ?? []
                ended = more?.ended ?? false
            }
        }
        return FeedPage(
            entries: entries,
            nextPageToken: continuation == nil || ended ? nil : Self.continuationToken,
            isCold: false,
            // A window with no continuation is the end only when it is the
            // whole set; otherwise its last post may be the middle of one.
            isEndOfSource: ended || (continuation == nil && isCompleteSet)
        )
    }

    /// `entries` of the window's kind; all of them without a scope.
    private func kept(_ entries: [FeedEntry]) -> [FeedEntry] {
        guard let scope else { return entries }
        return entries.filter(scope.admits)
    }

    /// The source's next posts, hydrated (#638).
    ///
    /// ⚠️ An EMPTY step throws: the source had nothing right now (a failed
    /// page), and a throw is what keeps the feed's token, so its next approach
    /// asks again. Only `nil` — the source has no more — ends the feed.
    func loadPage(afterToken token: String) async throws -> FeedPage {
        guard continuation != nil, let after = lastServed else {
            return FeedPage(entries: [], nextPageToken: nil, isCold: false)
        }
        let page = try await followOn(after: after, wanting: scope == nil ? 1 : Self.scopedPageMinimum)
        guard !page.ended else {
            // The source said so: nothing follows (#628) — after whatever of
            // this kind the last asks still found.
            return FeedPage(entries: page.entries, nextPageToken: nil, isCold: false, isEndOfSource: true)
        }
        // Nothing of this kind yet, the source not over: the feed keeps its
        // token and asks again on its next approach.
        guard !page.entries.isEmpty else { throw FeedContinuationError.nothingYet }
        return FeedPage(entries: page.entries, nextPageToken: Self.continuationToken, isCold: false)
    }

    /// Asks the continuation for what follows `after` until `wanting` posts of
    /// the window's kind have come, the source ends (`ended`), or the asks run
    /// out — `maxEmptySteps` unscoped (any non-empty step is a page), and
    /// `maxFillRounds` scoped.
    ///
    /// ⚠️ An EMPTY step throws when nothing has come yet: the source had
    /// nothing right now (a failed page), and a throw is what keeps the feed's
    /// token, so its next approach asks again. Only `nil` — the source has no
    /// more — ends the feed.
    private func followOn(after start: PostID, wanting: Int) async throws -> (entries: [FeedEntry], ended: Bool) {
        guard let continuation else { return ([], true) }
        var after = start
        var found: [FeedEntry] = []
        for _ in 0..<(scope == nil ? Self.maxEmptySteps : Self.maxFillRounds) {
            guard let next = await continuation(after) else { return (found, true) }
            guard let last = next.last else {
                if found.isEmpty { throw FeedContinuationError.nothingYet }
                return (found, false)
            }
            after = last
            lastServed = last
            found += kept(await hydrate(next))
            if found.count >= wanting { break }
        }
        return (found, false)
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

    func revalidatePost(_ id: PostID) async throws -> FeedEntry {
        try await base.revalidatePost(id)
    }

    /// Each post comes from `base.loadPost`, whose cache keeps a count as it
    /// was fetched.
    nonisolated var pagesCarryFreshCounts: Bool { false }

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
