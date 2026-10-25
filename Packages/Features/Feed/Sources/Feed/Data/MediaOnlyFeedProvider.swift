import CoreModels
import Foundation

/// (#1699, the owner 2026-10-24): the For You root lists MEDIA
/// posts only — a text-only post is filtered out of every page its source
/// serves.
///
/// "Media" is what the snap feed will DRAW as a media page: the post's first
/// attachment has a URL (`FeedDisplayModelBuilder` takes `attachments.first`'s
/// `url`). Not `attachments.isEmpty` alone — an attachment with no URL renders
/// as a text page.
///
/// ⚠️ A FILTERED PAGE MAY COME OUT SHORT, OR EMPTY. It keeps reading on —
/// the source's next page — while it holds fewer than `pageMinimum` media
/// posts and the source has more, up to `maxHops` reads, and answers with the
/// LAST token it read past, so paging never re-reads the same text-only
/// pages. `FeedViewModel` re-checks paging after a page that added nothing
/// (an empty page is still progress).
///
/// Everything else is the source's: the peek cache, warming, remembering, and
/// whether its counts are fresh.
actor MediaOnlyFeedProvider: FeedProviding {
    private let base: any FeedProviding
    private let pageMinimum: Int
    private let maxHops: Int

    init(base: any FeedProviding, pageMinimum: Int = 5, maxHops: Int = 8) {
        self.base = base
        self.pageMinimum = pageMinimum
        self.maxHops = maxHops
    }

    /// Whether `entry` is drawn as a media page.
    nonisolated static func admits(_ entry: FeedEntry) -> Bool {
        entry.post.attachments.first?.url != nil
    }

    /// `nil` when no cached post is media: an empty copy would put the feed
    /// in its content phase with nothing to show until the network answers.
    func cachedFirstPage() async -> [FeedEntry]? {
        guard let media = await base.cachedFirstPage()?.filter(Self.admits), !media.isEmpty else { return nil }
        return media
    }

    func loadFirstPage() async throws -> FeedPage {
        try await filled(try await base.loadFirstPage())
    }

    func loadPage(afterToken token: String) async throws -> FeedPage {
        try await filled(try await base.loadPage(afterToken: token))
    }

    /// `first`'s media posts, topped up from the source's next pages.
    private func filled(_ first: FeedPage) async throws -> FeedPage {
        var entries = first.entries.filter(Self.admits)
        var page = first
        var hops = 0
        while entries.count < pageMinimum, let token = page.nextPageToken, !page.isEndOfSource, hops < maxHops {
            hops += 1
            page = try await base.loadPage(afterToken: token)
            let seen = Set(entries.map(\.post.id))
            entries += page.entries.filter { Self.admits($0) && !seen.contains($0.post.id) }
        }
        return FeedPage(
            entries: entries, nextPageToken: page.nextPageToken,
            isCold: first.isCold || page.isCold, isEndOfSource: page.isEndOfSource
        )
    }

    func loadPost(_ id: PostID) async throws -> FeedEntry { try await base.loadPost(id) }
    func revalidatePost(_ id: PostID) async throws -> FeedEntry { try await base.revalidatePost(id) }
    func prewarm(_ ids: [PostID]) async { await base.prewarm(ids) }
    func remember(_ entry: FeedEntry) async { await base.remember(entry) }
    nonisolated func peekPost(_ id: PostID) -> FeedEntry? { base.peekPost(id) }
    nonisolated func didShow(_ id: PostID) { base.didShow(id) }
    nonisolated var pagesCarryFreshCounts: Bool { base.pagesCarryFreshCounts }
}
