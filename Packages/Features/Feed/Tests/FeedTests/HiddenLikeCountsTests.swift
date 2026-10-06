import AuthInterface
import CoreContracts
import CoreModels
import CoreNetworking
import CoreNetworkingMocks
import Foundation
import Testing
@testable import Feed

/// A post whose author hides like counts (#397, backend #809) shows no
/// number — not a 0 — on every surface that would show one.
struct HiddenLikeCountsTests {
    private struct Session: AuthSessionProviding {
        func currentState() async -> AuthState { .authenticated(AccountID(MockAuthService.accountID)) }
        func stateUpdates() async -> AsyncStream<AuthState> {
            AsyncStream { $0.yield(.authenticated(AccountID(MockAuthService.accountID))); $0.finish() }
        }
        func logout() async {}
    }

    private func makeRepository() -> (FeedRepository, MockSocialDataset) {
        let dataset = MockSocialDataset()
        let bff = MockBFF()
        let store = MockCounterStore(dataset: dataset)
        MockSocialServices(dataset: dataset, counters: store).register(on: bff)
        MockEngagementService(store: store).register(on: bff)
        MockCounterService(store: store).register(on: bff)
        let client = ConnectClientFactory.makeUnauthenticated(host: "https://mock.bff.local", httpClient: bff)
        let repository = FeedRepository(
            timelineClient: Timeline_V1_TimelineServiceClient(client: client),
            postClient: Post_V1_PostServiceClient(client: client),
            profileClient: Profile_V1_ProfileServiceClient(client: client),
            counterClient: Counter_V1_CounterServiceClient(client: client),
            engagementClient: Engagement_V1_EngagementServiceClient(client: client),
            authSession: Session(),
            snapshotStore: nil
        )
        return (repository, dataset)
    }

    /// prof-13 hides its like counts (the mock's seed); everyone else shows them.
    @Test func aHidingAuthorsPostCarriesNoVisibleCount() async throws {
        let (repository, dataset) = makeRepository()
        let hidden = try #require(dataset.posts.first { $0.authorProfileID == "prof-13" })
        let shown = try #require(dataset.posts.first { $0.authorProfileID != "prof-13" && $0.authorProfileID != MockSocialDataset.viewerProfileID })

        let hiddenEntry = try await repository.loadPost(PostID(hidden.postID))
        #expect(hiddenEntry.post.likeCountsHidden)
        #expect(hiddenEntry.visibleLikeCount == nil)
        #expect(FeedDisplayModelBuilder().build([hiddenEntry], relativeTo: Date())[0].visibleLikeCount == nil)

        let shownEntry = try await repository.loadPost(PostID(shown.postID))
        #expect(!shownEntry.post.likeCountsHidden)
        #expect(shownEntry.visibleLikeCount == shownEntry.likeCount)
        #expect(FeedDisplayModelBuilder().build([shownEntry], relativeTo: Date())[0].visibleLikeCount == shownEntry.likeCount)
    }

    /// The post page keeps the heart and drops the number.
    @MainActor
    @Test func thePostPageShowsNoCountForAHidingAuthor() async throws {
        let (repository, dataset) = makeRepository()
        let hidden = try #require(dataset.posts.first { $0.authorProfileID == "prof-13" })
        let viewModel = PostDetailViewModel(postID: PostID(hidden.postID), repository: repository)
        var engagement: PostDetailViewModel.EngagementState?
        viewModel.onEngagementChange = { engagement = $0 }
        viewModel.viewDidLoad()
        for _ in 0..<2_000 where engagement == nil {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(engagement?.countHidden == true)
    }

    /// Snapshots written before the field still decode, as showing counts.
    @Test func anOlderSnapshotDecodesAsShowingCounts() throws {
        let json = #"{"id":"p","authorID":"a","caption":"","attachments":[],"publishedAt":0}"#
        let post = try JSONDecoder().decode(Post.self, from: Data(json.utf8))
        #expect(!post.likeCountsHidden)
        let roundTrip = try JSONDecoder().decode(Post.self, from: JSONEncoder().encode(
            Post(id: PostID("p"), authorID: ProfileID("a"), caption: "", attachments: [], publishedAt: Date(), likeCountsHidden: true)
        ))
        #expect(roundTrip.likeCountsHidden)
    }
}
