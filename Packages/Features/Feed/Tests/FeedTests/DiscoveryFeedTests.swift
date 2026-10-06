import AuthInterface
import CoreContracts
import CoreModels
import CoreNetworking
import CoreNetworkingMocks
import Foundation
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
        contentLevel: DiscoveryContentLevel = .restricted
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
            snapshotStore: nil
        )
        let discovery = DiscoveryFeedRepository(
            timelineClient: Timeline_V1_TimelineServiceClient(client: client),
            base: base,
            contentLevel: { contentLevel },
            region: { "FR" },
            pageSize: 10
        )
        return (discovery, bff, dataset)
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

    @Test func pagesFollowTheServersCursor() async throws {
        let (discovery, _, _) = makeDiscovery()
        let first = try await discovery.loadFirstPage()
        let second = try await discovery.loadPage(afterToken: try #require(first.nextPageToken))
        #expect(!second.entries.isEmpty)
        #expect(Set(first.entries.map(\.post.id)).isDisjoint(with: second.entries.map(\.post.id)))
    }
}

// MARK: - The view model's two corpora

private func tile(_ id: String, author: String = "stranger", publishedAtMS: Int64 = 0, reactions: Int64 = 0) -> GalleryPost {
    GalleryPost(
        id: PostID(id), kind: .photo, isRepost: false, thumbnailURL: nil, caption: id,
        publishedAtMS: publishedAtMS, authorID: ProfileID(author), reactionCount: reactions
    )
}

private final class TwoCorporaProvider: ForYouProviding, @unchecked Sendable {
    let following: ForYouPage?
    var discovery: [String: ForYouPage] = [:]
    init(following: ForYouPage?, discoveryFirst: ForYouPage) {
        self.following = following
        discovery[""] = discoveryFirst
    }
    func firstPage() async throws -> ForYouPage {
        guard let following else { throw FeedError.transport(message: "a guest has no timeline") }
        return following
    }
    func page(after token: String) async throws -> ForYouPage { ForYouPage(posts: [], nextPageToken: nil) }
    func discoveryFirstPage() async throws -> ForYouPage? { discovery[""] }
    func discoveryPage(after token: String) async throws -> ForYouPage? { discovery[token] }
}

/// Runs `action` and returns once the model says a load settled — the
/// callback the view closes its refresh control on — rather than guessing a
/// number of yields.
@MainActor
private func loading(_ model: ForYouViewModel, _ action: () -> Void) async {
    await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
        var resumed = false
        model.onLoadSettled = {
            guard !resumed else { return }
            resumed = true
            done.resume()
        }
        action()
    }
    model.onLoadSettled = nil
}

@MainActor
struct ForYouDiscoveryCorpusTests {
    private func content(_ state: ForYouViewModel.PageState) -> [String] {
        if case .content(let posts) = state { return posts.map(\.id.rawValue) }
        return []
    }

    /// Discover keeps the SERVER's order — no client re-ranking — and the
    /// rows are the following timeline's, not the pool's.
    @Test func discoverIsThePoolAndTheRowsAreTheTimeline() async {
        let provider = TwoCorporaProvider(
            following: ForYouPage(posts: [tile("f1", author: "followed", publishedAtMS: 5)], nextPageToken: nil),
            discoveryFirst: ForYouPage(posts: [
                tile("d1", reactions: 1), tile("d2", reactions: 50), tile("d3", reactions: 9)
            ], nextPageToken: nil)
        )
        let model = ForYouViewModel(repository: provider, unreadStore: ForYouUnreadStore(defaults: UserDefaults(suiteName: UUID().uuidString)!))
        var snapshot: ForYouViewModel.Snapshot?
        model.onSnapshotChange = { snapshot = $0 }
        await loading(model) { model.viewDidLoad() }

        #expect(content(snapshot?.discover ?? .loading) == ["d1", "d2", "d3"])
        #expect(content(snapshot?.following ?? .loading) == ["f1"])
        #expect(snapshot?.rails.following.map(\.id.rawValue) == ["f1"])
        // A card offers Unfollow for a followed author only — never for an
        // author the pool ranked.
        #expect(model.isFollowed(ProfileID("followed")))
        #expect(!model.isFollowed(ProfileID("stranger")))
    }

    /// A guest has no timeline: the rows stay empty and Discover still shows.
    @Test func aGuestStillDiscovers() async {
        let provider = TwoCorporaProvider(
            following: nil,
            discoveryFirst: ForYouPage(posts: [tile("d1"), tile("d2")], nextPageToken: nil)
        )
        let model = ForYouViewModel(repository: provider, unreadStore: ForYouUnreadStore(defaults: UserDefaults(suiteName: UUID().uuidString)!))
        var snapshot: ForYouViewModel.Snapshot?
        model.onSnapshotChange = { snapshot = $0 }
        await loading(model) { model.viewDidLoad() }

        #expect(content(snapshot?.discover ?? .loading) == ["d1", "d2"])
        #expect(snapshot?.rails.following.isEmpty == true)
    }

    /// Paging appends the pool in order and drops a post served twice (it
    /// moved between rankings, which the contract allows).
    @Test func pagingAppendsThePoolOnce() async {
        let provider = TwoCorporaProvider(
            following: ForYouPage(posts: [], nextPageToken: nil),
            discoveryFirst: ForYouPage(posts: [tile("d1"), tile("d2")], nextPageToken: "t2")
        )
        provider.discovery["t2"] = ForYouPage(posts: [tile("d2"), tile("d3")], nextPageToken: nil)
        let model = ForYouViewModel(repository: provider, unreadStore: ForYouUnreadStore(defaults: UserDefaults(suiteName: UUID().uuidString)!))
        var snapshot: ForYouViewModel.Snapshot?
        model.onSnapshotChange = { snapshot = $0 }
        await loading(model) { model.viewDidLoad() }
        #expect(model.hasMorePages)

        await loading(model) { model.loadNextPageIfNeeded() }

        #expect(content(snapshot?.discover ?? .loading) == ["d1", "d2", "d3"])
        #expect(!model.hasMorePages)
    }
}
