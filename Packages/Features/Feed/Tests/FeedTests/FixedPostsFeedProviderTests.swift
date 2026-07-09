import CoreModels
import Foundation
import Testing
@testable import Feed

struct FixedPostsFeedProviderTests {
    @Test func loadFirstPagePreservesRequestedOrder() async throws {
        let base = StubBase(entries: [
            "a": entry("a"), "b": entry("b"), "c": entry("c")
        ])
        let provider = FixedPostsFeedProvider(base: base, ids: [PostID("c"), PostID("a"), PostID("b")])

        let page = try await provider.loadFirstPage()

        #expect(page.entries.map(\.post.id) == [PostID("c"), PostID("a"), PostID("b")])
        #expect(page.nextPageToken == nil) // fixed set → never paginates
    }

    @Test func dropsPostsThatFailToHydrateWithoutFailingThePage() async throws {
        // "b" is missing from the base → its loadPost throws and it's skipped,
        // rather than blanking the whole feed.
        let base = StubBase(entries: ["a": entry("a"), "c": entry("c")])
        let provider = FixedPostsFeedProvider(base: base, ids: [PostID("a"), PostID("b"), PostID("c")])

        let page = try await provider.loadFirstPage()

        #expect(page.entries.map(\.post.id) == [PostID("a"), PostID("c")])
    }

    @Test func secondPageIsAlwaysEmpty() async throws {
        let base = StubBase(entries: ["a": entry("a")])
        let provider = FixedPostsFeedProvider(base: base, ids: [PostID("a")])

        let page = try await provider.loadPage(afterToken: "anything")

        #expect(page.entries.isEmpty)
        #expect(page.nextPageToken == nil)
    }

    @Test func cachedFirstPageIsNil() async {
        let provider = FixedPostsFeedProvider(base: StubBase(entries: [:]), ids: [])
        #expect(await provider.cachedFirstPage() == nil)
    }

    // MARK: - Helpers

    private func entry(_ id: String) -> FeedEntry {
        FeedEntry(
            post: Post(id: PostID(id), authorID: ProfileID("author-\(id)"), caption: id, attachments: [], publishedAt: Date(timeIntervalSince1970: 0)),
            author: AuthorSummary(id: ProfileID("author-\(id)"), handle: id, displayName: id, avatarURL: nil),
            likeCount: 0
        )
    }
}

private struct StubBase: FeedProviding {
    let entries: [String: FeedEntry]

    func cachedFirstPage() async -> [FeedEntry]? { nil }
    func loadFirstPage() async throws -> FeedPage { FeedPage(entries: [], nextPageToken: nil, isCold: false) }
    func loadPage(afterToken token: String) async throws -> FeedPage { FeedPage(entries: [], nextPageToken: nil, isCold: false) }

    func loadPost(_ id: PostID) async throws -> FeedEntry {
        guard let entry = entries[id.rawValue] else {
            throw FeedError.transport(message: "no post \(id)")
        }
        return entry
    }
}
