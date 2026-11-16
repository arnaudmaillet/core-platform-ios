import AuthInterface
import CoreContracts
import CoreModels
import CoreNetworking
import CoreNetworkingMocks
import Foundation
import LocalStore
import PostGrid
import Testing
@testable import Feed

/// Discover reads its own pool (`timeline.v1.GetDiscoveryFeed`, backend B3,
/// #512): everyone's posts, in the server's order, for guests and members —
/// while the rows keep reading the following timeline.
struct DiscoveryFeedRepositoryTests {
    private struct GuestSession: AuthSessionProviding {
        func currentState() async -> AuthState { .unauthenticated }
        func stateUpdates() async -> AsyncStream<AuthState> {
            AsyncStream { $0.yield(.unauthenticated); $0.finish() }
        }
        func logout() async {}
    }

    private func makeDiscovery(
        reader: DiscoveryReader = .guest, localCache: FeedLocalCache? = nil
    ) -> (DiscoveryFeedRepository, MockBFF, MockSocialDataset) {
        let dataset = MockSocialDataset()
        let bff = MockBFF()
        let store = MockCounterStore(dataset: dataset)
        MockSocialServices(dataset: dataset, counters: store).register(on: bff)
        MockEngagementService(store: store).register(on: bff)
        MockCounterService(store: store).register(on: bff)
        let client = ConnectClientFactory.makeUnauthenticated(host: "https://mock.bff.local", httpClient: bff)
        let base = FeedRepository(
            timelineClient: Timeline_V1_TimelineServiceClient(client: client),
            postClient: Post_V1_PostServiceClient(client: client),
            profileClient: Profile_V1_ProfileServiceClient(client: client),
            counterClient: Counter_V1_CounterServiceClient(client: client),
            engagementClient: Engagement_V1_EngagementServiceClient(client: client),
            authSession: GuestSession(),
            localCache: nil
        )
        let discovery = DiscoveryFeedRepository(
            timelineClient: Timeline_V1_TimelineServiceClient(client: client),
            base: base,
            reader: { reader },
            region: { "FR" },
            pageSize: 10,
            localCache: localCache
        )
        return (discovery, bff, dataset)
    }

    /// ⚠️ SHOTS OPENS ON THE DEVICE'S COPY (#1765): the Discover pool's first
    /// page is stored per viewer, and the next launch reads it back without a
    /// request — the launch screen's first post in its first frame.
    @Test func theFirstPageIsKeptForTheNextLaunch() async throws {
        let folder = StoreFolder()
        let cache = FeedLocalCache(store: try LocalStore(directory: folder.url, viewer: { .guest }))
        let (session, _, _) = makeDiscovery(localCache: cache)
        #expect(await session.cachedFirstPage() == nil, "nothing stored yet")
        let first = try await session.loadFirstPage()

        let relaunched = FeedLocalCache(store: try LocalStore(directory: folder.url, viewer: { .guest }))
        let (next, bff, _) = makeDiscovery(localCache: relaunched)
        let cached = try #require(await next.cachedFirstPage())
        #expect(cached == first.entries, "the first page, as the network served it")
        #expect(bff.recordedRequests.isEmpty, "the copy cost a request")
    }

    /// No following timeline needed: a guest gets posts from everyone.
    @Test func aGuestDiscoversPostsFromEveryone() async throws {
        let (discovery, bff, _) = makeDiscovery()
        let page = try await discovery.loadFirstPage()
        #expect(page.entries.count == 10)
        #expect(Set(page.entries.map(\.author.id)).count > 1, "more than one author")
        #expect(page.nextPageToken != nil)
        #expect(bff.recordedRequests.contains { $0.path == "/timeline.v1.TimelineService/GetDiscoveryFeed" })
        #expect(!bff.recordedRequests.contains { $0.path == "/timeline.v1.TimelineService/GetFollowingFeed" })
    }

    /// A member's page is ranked by its interest tags (#413, timeline #662):
    /// posts tagged with one come first, and a removed tag stops pulling its
    /// posts up — the issue's "a deleted tag stops influencing For You".
    @Test func aRemovedInterestStopsRankingForYou() async throws {
        let member = DiscoveryReader(contentLevel: .restricted, profileID: MockSocialDataset.viewerProfileID, nonPersonalized: false)
        let (discovery, bff, dataset) = makeDiscovery(reader: member)
        let captions = Dictionary(dataset.posts.map { ($0.postID, $0.caption.lowercased()) }, uniquingKeysWith: { first, _ in first })
        func tagged(_ tag: String, _ page: FeedPage) -> [Bool] {
            page.entries.map { captions[$0.post.id.rawValue]?.contains("#" + tag) ?? false }
        }
        let timeline = Timeline_V1_TimelineServiceClient(
            client: ConnectClientFactory.makeUnauthenticated(host: "https://mock.bff.local", httpClient: bff)
        )
        // Keep only #travel, so the ranking has one tag to follow.
        for interest in MockSocialServices.seededInterests where interest.tag != "travel" {
            var remove = Timeline_V1_RemoveInterestRequest()
            remove.profileID = MockSocialDataset.viewerProfileID
            remove.tag = interest.tag
            _ = try await timeline.removeInterest(request: remove, headers: [:]).result.get()
        }
        let ranked = try await discovery.loadFirstPage()
        let travel = tagged("travel", ranked)
        #expect(travel.first == true, "a #travel post leads")
        #expect(!travel.drop(while: { $0 }).contains(true), "every #travel post comes before the rest")

        var remove = Timeline_V1_RemoveInterestRequest()
        remove.profileID = MockSocialDataset.viewerProfileID
        remove.tag = "#travel"
        #expect(try await timeline.removeInterest(request: remove, headers: [:]).result.get().interests.isEmpty)
        let unranked = try await discovery.loadFirstPage()
        let (guest, _, _) = makeDiscovery()
        #expect(unranked.entries.map(\.post.id) == (try await guest.loadFirstPage()).entries.map(\.post.id),
                "with no tags left, the page is everyone's")
    }

    /// Personalised Recommendations off: the reader's tags are ignored.
    @Test func aNonPersonalisedReaderGetsEveryonesPage() async throws {
        let reader = DiscoveryReader(contentLevel: .restricted, profileID: MockSocialDataset.viewerProfileID, nonPersonalized: true)
        let (discovery, _, _) = makeDiscovery(reader: reader)
        let (guest, _, _) = makeDiscovery()
        #expect(try await discovery.loadFirstPage().entries.map(\.post.id) == (try await guest.loadFirstPage()).entries.map(\.post.id))
    }

    @Test func pagesFollowTheServersCursor() async throws {
        let (discovery, _, _) = makeDiscovery()
        let first = try await discovery.loadFirstPage()
        let second = try await discovery.loadPage(afterToken: try #require(first.nextPageToken))
        #expect(!second.entries.isEmpty)
        #expect(Set(first.entries.map(\.post.id)).isDisjoint(with: second.entries.map(\.post.id)))
    }
}
