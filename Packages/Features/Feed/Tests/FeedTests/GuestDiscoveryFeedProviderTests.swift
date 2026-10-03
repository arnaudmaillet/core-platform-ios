import CoreModels
import Foundation
import Testing
@testable import Feed

private func entry(_ id: String) -> FeedEntry {
    FeedEntry(
        post: Post(
            id: PostID(id),
            authorID: ProfileID("author"),
            caption: id,
            attachments: [],
            publishedAt: Date(timeIntervalSince1970: 0)
        ),
        author: AuthorSummary(id: ProfileID("author"), handle: "a", displayName: "A", avatarURL: nil),
        likeCount: 0
    )
}

/// The repository a guest's corpus hydrates through: it knows every post but
/// "gone", and has no timeline to give.
private struct HydratingFeed: FeedProviding {
    func cachedFirstPage() async -> [FeedEntry]? { nil }
    func loadFirstPage() async throws -> FeedPage { throw CancellationError() }
    func loadPage(afterToken token: String) async throws -> FeedPage { throw CancellationError() }
    func loadPost(_ id: PostID) async throws -> FeedEntry {
        guard id.rawValue != "gone" else { throw CancellationError() }
        return entry(id.rawValue)
    }
}

/// Guest mode: For You's corpus without a following timeline.
struct GuestDiscoveryFeedProviderTests {
    @Test func theFirstPageIsTheGivenPostsInOrderAndNeverTheTimeline() async throws {
        let provider = GuestDiscoveryFeedProvider(base: HydratingFeed()) {
            [PostID("b"), PostID("gone"), PostID("a")]
        }

        let page = try await provider.loadFirstPage()

        // Hydrated through the repository, in the given order; a post that
        // cannot be read is dropped rather than failing the page.
        #expect(page.entries.map(\.post.id) == [PostID("b"), PostID("a")])
        #expect(page.nextPageToken == nil)
    }

    @Test func aFailingSourceFailsThePage() async {
        struct SourceDown: Error {}
        let provider = GuestDiscoveryFeedProvider(base: HydratingFeed()) { throw SourceDown() }

        await #expect(throws: SourceDown.self) { try await provider.loadFirstPage() }
    }
}
