import MediaCore
import CoreModels
import FeedInterface
import Testing
@testable import Feed

/// The snap feed is the app's sole Timeline, and its ONE post screen (#1577):
/// the builder always vends it, for the timeline and for a single post.
@MainActor
struct SnapFeedPresentationTests {
    @Test func feedBuilderVendsTheSnapViewController() {
        #expect(makeBuilder().makeFeedViewController() is SnapFeedViewController)
    }

    /// The `.post` and `.comments` routes open the vertical feed on the post —
    /// its comments asked for on the second — never a standalone detail screen.
    @Test func aSinglePostOpensTheVerticalFeed() throws {
        let post = try #require(makeBuilder().makePostFeedViewController(for: PostID("p1"), opensComments: false)
            as? SnapFeedViewController)
        #expect(post.debugPendingCommentsID == nil && post.debugRestingCommentsID == nil)
        let comments = try #require(makeBuilder().makePostFeedViewController(for: PostID("p1"), opensComments: true)
            as? SnapFeedViewController)
        #expect(comments.debugPendingCommentsID == PostID("p1") || comments.debugRestingCommentsID == PostID("p1"),
                "the comments were not asked for")
    }

    private func makeBuilder() -> FeedFeatureBuilder {
        FeedFeatureBuilder(
            repository: StubFeedProvider(),
            imagePipeline: ImagePipeline(fetcher: PlaceholderImageFetcher())
        )
    }
}

private struct StubFeedProvider: FeedProviding {
    func cachedFirstPage() async -> [FeedEntry]? { nil }
    func loadFirstPage() async throws -> FeedPage { FeedPage(entries: [], nextPageToken: nil, isCold: false) }
    func loadPage(afterToken token: String) async throws -> FeedPage { FeedPage(entries: [], nextPageToken: nil, isCold: false) }
    func loadPost(_ id: PostID) async throws -> FeedEntry { throw FeedError.transport(message: "unused") }
}
