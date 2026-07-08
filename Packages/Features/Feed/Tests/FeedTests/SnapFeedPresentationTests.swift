import CoreMedia
import CoreModels
import FeedInterface
import Testing
@testable import Feed

/// The composition root's presentation switch must route to the right view
/// controller — that's the entire contract Phase 1 adds to the builder.
@MainActor
struct SnapFeedPresentationTests {
    @Test func snapPresentationBuildsTheSnapViewController() {
        let vc = makeBuilder(presentation: .snap).makeFeedViewController()
        #expect(vc is SnapFeedViewController)
    }

    @Test func classicPresentationBuildsTheClassicViewController() {
        let vc = makeBuilder(presentation: .classic).makeFeedViewController()
        #expect(vc is FeedViewController)
    }

    @Test func defaultPresentationIsClassic() {
        // Callers that predate the snap feed keep the list, untouched.
        let builder = FeedFeatureBuilder(
            repository: StubFeedProvider(),
            imagePipeline: ImagePipeline(fetcher: PlaceholderImageFetcher())
        )
        #expect(builder.makeFeedViewController() is FeedViewController)
    }

    private func makeBuilder(presentation: FeedPresentationStyle) -> FeedFeatureBuilder {
        FeedFeatureBuilder(
            repository: StubFeedProvider(),
            imagePipeline: ImagePipeline(fetcher: PlaceholderImageFetcher()),
            presentation: presentation
        )
    }
}

private struct StubFeedProvider: FeedProviding {
    func cachedFirstPage() async -> [FeedEntry]? { nil }
    func loadFirstPage() async throws -> FeedPage { FeedPage(entries: [], nextPageToken: nil, isCold: false) }
    func loadPage(afterToken token: String) async throws -> FeedPage { FeedPage(entries: [], nextPageToken: nil, isCold: false) }
    func loadPost(_ id: PostID) async throws -> FeedEntry { throw FeedError.transport(message: "unused") }
}
