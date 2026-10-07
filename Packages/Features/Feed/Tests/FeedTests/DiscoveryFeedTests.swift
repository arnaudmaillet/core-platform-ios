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
        reader: DiscoveryReader = .guest
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
            reader: { reader },
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

    /// Personalised For You off: the reader's tags are ignored.
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

/// Records which corpus each page was asked of (#566). In the app's
/// `ForYouRepository`, `page(after:)` is `GetFollowingFeed` with that token and
/// `discoveryPage(after:)` is `GetDiscoveryFeed`.
private final class RecordingCorporaProvider: ForYouProviding, @unchecked Sendable {
    private(set) var followingTokens: [String] = []
    private(set) var discoveryTokens: [String] = []
    var followingPages: [String: ForYouPage] = [:]
    var followingFirst = ForYouPage(posts: [], nextPageToken: nil)
    var discoveryFirst = ForYouPage(posts: [], nextPageToken: nil)
    func firstPage() async throws -> ForYouPage { followingFirst }
    func page(after token: String) async throws -> ForYouPage {
        followingTokens.append(token)
        return followingPages[token] ?? ForYouPage(posts: [], nextPageToken: nil)
    }
    func discoveryFirstPage() async throws -> ForYouPage? { discoveryFirst }
    func discoveryPage(after token: String) async throws -> ForYouPage? {
        discoveryTokens.append(token)
        return ForYouPage(posts: [], nextPageToken: nil)
    }
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

    /// #566: with discovery wired (always, in the app), the end of a pushed
    /// Following or Friends list pages the FOLLOWING timeline with its own
    /// token — not Discover — and only the lists' footer follows that load.
    @Test func theFollowingListPagesTheFollowingTimeline() async {
        let provider = RecordingCorporaProvider()
        provider.followingFirst = ForYouPage(posts: [tile("f1", author: "followed")], nextPageToken: "f2")
        provider.followingPages["f2"] = ForYouPage(posts: [tile("f3", author: "followed")], nextPageToken: nil)
        provider.discoveryFirst = ForYouPage(posts: [tile("d1"), tile("d2")], nextPageToken: "d2")
        let model = ForYouViewModel(repository: provider, unreadStore: ForYouUnreadStore(defaults: UserDefaults(suiteName: UUID().uuidString)!))
        var followingFooter: [Bool] = []
        var discoverFooter: [Bool] = []
        model.onFollowingPagingChange = { followingFooter.append($0) }
        model.onPagingChange = { discoverFooter.append($0) }
        await loading(model) { model.viewDidLoad() }
        #expect(model.hasMoreFollowingPages)

        await loading(model) { model.loadNextPageIfNeeded(.following) }

        #expect(provider.followingTokens == ["f2"], "GetFollowingFeed with the following token")
        #expect(provider.discoveryTokens.isEmpty, "never GetDiscoveryFeed")
        #expect(followingFooter == [true, false], "the lists' footer follows the load")
        #expect(discoverFooter.isEmpty, "Discover's footer stays out of it")
        #expect(!model.hasMoreFollowingPages, "stops once next_page_token is empty")

        model.loadNextPageIfNeeded(.following)
        #expect(provider.followingTokens == ["f2"], "nothing more to ask")

        // Discover's grid and "View all" still page Discover.
        await loading(model) { model.loadNextPageIfNeeded(.discover) }
        #expect(provider.discoveryTokens == ["d2"])
        #expect(provider.followingTokens == ["f2"])
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

        await loading(model) { model.loadNextPageIfNeeded(.discover) }

        #expect(content(snapshot?.discover ?? .loading) == ["d1", "d2", "d3"])
        #expect(!model.hasMorePages)
    }
}
