import CoreModels
import Foundation
import Testing
@testable import Feed

/// EXPERIMENTAL (#1699): the For You root's source keeps media posts only,
/// tops a short page up from the next ones, and never re-reads what it has
/// passed.
struct MediaOnlyFeedProviderTests {
    private static func entry(_ id: String, media: Bool) -> FeedEntry {
        let attachments: [MediaAttachment] = media
            ? [MediaAttachment(url: URL(string: "mock://media/\(id)"), thumbnailURL: nil, mimeType: "image/jpeg", pixelWidth: 100, pixelHeight: 100)]
            : []
        return FeedEntry(
            post: Post(id: PostID(id), authorID: ProfileID("a"), caption: id, attachments: attachments,
                       publishedAt: Date(timeIntervalSince1970: 0)),
            author: AuthorSummary(id: ProfileID("a"), handle: "a", displayName: "A", avatarURL: nil),
            likeCount: 0
        )
    }

    /// Pages keyed by the token that reads them ("" = the first).
    private actor Pages: FeedProviding {
        let pages: [String: FeedPage]
        private(set) var reads: [String] = []
        init(_ pages: [String: FeedPage]) { self.pages = pages }
        func cachedFirstPage() async -> [FeedEntry]? { pages[""]?.entries }
        func loadFirstPage() async throws -> FeedPage { reads.append(""); return pages[""]! }
        func loadPage(afterToken token: String) async throws -> FeedPage { reads.append(token); return pages[token]! }
        func loadPost(_ id: PostID) async throws -> FeedEntry { throw URLError(.fileDoesNotExist) }
    }

    @Test func textOnlyPostsAreFilteredAndAShortPageIsToppedUp() async throws {
        let base = Pages([
            "": FeedPage(entries: [Self.entry("t1", media: false), Self.entry("m1", media: true)], nextPageToken: "p2", isCold: false),
            "p2": FeedPage(entries: [Self.entry("t2", media: false), Self.entry("t3", media: false)], nextPageToken: "p3", isCold: false),
            "p3": FeedPage(entries: [Self.entry("m2", media: true)], nextPageToken: nil, isCold: false, isEndOfSource: true),
        ])
        let provider = MediaOnlyFeedProvider(base: base, pageMinimum: 2, maxHops: 8)
        let page = try await provider.loadFirstPage()
        #expect(page.entries.map(\.post.id.rawValue) == ["m1", "m2"])
        #expect(page.nextPageToken == nil && page.isEndOfSource, "the page did not end where its source ended")
        #expect(await base.reads == ["", "p2", "p3"])
    }

    /// The hop cap holds, and the token handed back is the last one read past.
    @Test func theHopsAreCappedAndTheLastTokenIsKept() async throws {
        let base = Pages([
            "": FeedPage(entries: [Self.entry("t1", media: false)], nextPageToken: "p2", isCold: false),
            "p2": FeedPage(entries: [Self.entry("t2", media: false)], nextPageToken: "p3", isCold: false),
            "p3": FeedPage(entries: [Self.entry("t3", media: false)], nextPageToken: "p4", isCold: false),
        ])
        let provider = MediaOnlyFeedProvider(base: base, pageMinimum: 5, maxHops: 2)
        let page = try await provider.loadFirstPage()
        #expect(page.entries.isEmpty)
        #expect(page.nextPageToken == "p4", "it would re-read pages it passed")
    }

    @Test func aPostWithAnAttachmentButNoURLIsATextPage() {
        let urlless = FeedEntry(
            post: Post(id: PostID("x"), authorID: ProfileID("a"), caption: "x",
                       attachments: [MediaAttachment(url: nil, thumbnailURL: nil, mimeType: "image/jpeg", pixelWidth: 100, pixelHeight: 100)], publishedAt: Date(timeIntervalSince1970: 0)),
            author: AuthorSummary(id: ProfileID("a"), handle: "a", displayName: "A", avatarURL: nil),
            likeCount: 0
        )
        #expect(!MediaOnlyFeedProvider.admits(urlless))
        #expect(MediaOnlyFeedProvider.admits(Self.entry("m", media: true)))
    }
}
