import MediaCore
import CoreModels
import FeedInterface
import Testing
@testable import Feed

/// The snap feed is the app's sole Timeline; the builder always vends it, and
/// the post-detail builder honours the requested mode.
@MainActor
struct SnapFeedPresentationTests {
    @Test func feedBuilderVendsTheSnapViewController() {
        #expect(makeBuilder().makeFeedViewController() is SnapFeedViewController)
    }

    @Test func postDetailBuilderReturnsADetailViewControllerForBothModes() {
        #expect(makeBuilder().makePostDetailViewController(for: PostID("p1"), mode: .full) is PostDetailViewController)
        #expect(makeBuilder().makePostDetailViewController(for: PostID("p1"), mode: .commentsOnly) is PostDetailViewController)
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
