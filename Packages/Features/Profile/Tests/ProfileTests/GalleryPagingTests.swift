import CoreContracts
import CoreModels
import CoreNetworking
import CoreNetworkingMocks
import Foundation
import PostGrid
import Testing
@testable import Profile

// The profile gallery, page by page (#634).

private func post(_ id: String, _ kind: GalleryPost.Kind = .photo, at ms: Int64) -> GalleryPost {
    GalleryPost(id: PostID(id), kind: kind, isRepost: false, thumbnailURL: nil, caption: id, publishedAtMS: ms)
}

private struct GalleryStubError: Error {}

/// Serves each corpus's pages by token (nil = the first) and records every ask.
private actor PagedGallery: ProfileGalleryProviding {
    private var authored: [String?: GalleryPage]
    private var tagged: [String?: GalleryPage]
    private var failing: Set<String> = []
    private(set) var authoredAsks: [String?] = []
    private(set) var taggedAsks: [String?] = []

    init(authored: [String?: GalleryPage], tagged: [String?: GalleryPage] = [nil: GalleryPage(posts: [], nextPageToken: nil)]) {
        self.authored = authored
        self.tagged = tagged
    }

    func setAuthored(_ page: GalleryPage, for token: String?) { authored[token] = page }
    func fail(_ token: String) { failing.insert(token) }
    func heal(_ token: String) { failing.remove(token) }

    func authoredPage(for profileID: ProfileID, after pageToken: String?) async throws -> GalleryPage {
        authoredAsks.append(pageToken)
        if let pageToken, failing.contains(pageToken) { throw GalleryStubError() }
        return authored[pageToken] ?? GalleryPage(posts: [], nextPageToken: nil)
    }

    func taggedPage(for profileID: ProfileID, handle: String, after pageToken: String?) async throws -> GalleryPage {
        taggedAsks.append(pageToken)
        return tagged[pageToken] ?? GalleryPage(posts: [], nextPageToken: nil)
    }

    func authoredPosts(for profileID: ProfileID) async throws -> [GalleryPost] { [] }
    func taggedPosts(for profileID: ProfileID, handle: String) async throws -> [GalleryPost] { [] }
    func posts(ids: [String]) async throws -> [GalleryPost] { [] }
}

private actor OneProfile: ProfileProviding {
    let profile = UserProfile(
        id: ProfileID("prof-1"), handle: "ada", displayName: "Ada", bio: "",
        avatarURL: nil, websiteURL: nil, isVerified: false,
        followerCount: .exact(0), followingCount: .exact(0), reactionCount: .unavailable
    )
    func currentUserProfile() async throws -> UserProfile { profile }
    func profile(id: ProfileID) async throws -> UserProfile { profile }
    func relationship(for profileID: ProfileID) async throws -> ProfileRelationship {
        .other(isFollowing: false, isBlocked: false)
    }
    func setFollowing(_ following: Bool, for profileID: ProfileID) async throws {}
    func setBlocked(_ blocked: Bool, for profileID: ProfileID) async throws {}
    func blockAccount(behind profileID: ProfileID) async throws -> [ProfileID] { [profileID] }
    func updateCurrentUserProfile(displayName: String, bio: String, website: String, links: [ProfileLink]) async throws -> UserProfile { profile }
    func changeHandle(_ newHandle: String) async throws -> UserProfile { profile }
}

@MainActor
struct GalleryPagingTests {
    @MainActor
    private final class Shown {
        var snapshot: ProfileViewModel.GallerySnapshot?
    }

    private func settle(until condition: () async -> Bool) async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(60))
        while !(await condition()), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    /// Grace for "nothing more should happen".
    private func settle() async {
        try? await Task.sleep(for: .milliseconds(150))
    }

    private func ids(_ state: ProfileViewModel.GalleryPageState?) -> [String] {
        guard case .content(let posts) = state else { return [] }
        return posts.map(\.id.rawValue)
    }

    private func open(_ gallery: PagedGallery) async -> (ProfileViewModel, Shown) {
        let viewModel = ProfileViewModel(repository: OneProfile(), gallery: gallery, source: .profile(ProfileID("prof-1")))
        let shown = Shown()
        viewModel.onGalleryChange = { shown.snapshot = $0 }
        viewModel.viewDidLoad()
        await settle {
            if case .loading = shown.snapshot?.activity { return false }
            return shown.snapshot != nil
        }
        return (viewModel, shown)
    }

    @Test func nearingTheEndAppendsTheNextPageOnceAndStopsAtTheEnd() async {
        let gallery = PagedGallery(authored: [
            nil: GalleryPage(posts: [post("a", at: 60), post("b", at: 50)], nextPageToken: "a2"),
            "a2": GalleryPage(posts: [post("c", at: 40)], nextPageToken: nil),
        ])
        let (viewModel, shown) = await open(gallery)
        viewModel.setGallerySource(.posts)
        #expect(ids(shown.snapshot?.activity) == ["a", "b"])

        viewModel.loadMoreGallery()
        viewModel.loadMoreGallery() // the same approach, reported twice
        await settle { ids(shown.snapshot?.activity).count == 3 }
        #expect(ids(shown.snapshot?.activity) == ["a", "b", "c"])

        viewModel.loadMoreGallery() // the end: nothing left to ask
        await settle()
        #expect(await gallery.authoredAsks == [nil, "a2"])
    }

    /// All merges two corpora that page on their own: it shows only down to
    /// where both are known, so the next page only ever adds below.
    @Test func allStopsAtTheFrontierAndOnlyEverAppends() async {
        let gallery = PagedGallery(
            authored: [
                nil: GalleryPage(posts: [post("a", at: 100), post("b", at: 90)], nextPageToken: "a2"),
                "a2": GalleryPage(posts: [post("c", at: 50)], nextPageToken: nil),
            ],
            tagged: [nil: GalleryPage(posts: [post("t1", at: 95), post("t2", at: 10)], nextPageToken: nil)]
        )
        let (viewModel, shown) = await open(gallery)
        // t2 (10) is older than what the authored corpus has reached (90):
        // an authored post could still land between them, so it waits.
        #expect(ids(shown.snapshot?.activity) == ["a", "t1", "b"])

        viewModel.loadMoreGallery()
        await settle { ids(shown.snapshot?.activity).count == 5 }

        #expect(ids(shown.snapshot?.activity) == ["a", "t1", "b", "c", "t2"])
    }

    /// Short shows only text: a page of photos adds nothing to it, and with
    /// no tile coming on screen to ask, the next page is asked at once.
    @Test func aTabThatAPageLeavesUnchangedKeepsLoading() async {
        let gallery = PagedGallery(authored: [
            nil: GalleryPage(posts: [post("p1", at: 60)], nextPageToken: "a2"),
            "a2": GalleryPage(posts: [post("p2", at: 50)], nextPageToken: "a3"),
            "a3": GalleryPage(posts: [post("x", .text, at: 40)], nextPageToken: nil),
        ])
        let (viewModel, shown) = await open(gallery)

        viewModel.setGalleryFormat(.short)
        await settle { ids(shown.snapshot?.short) == ["x"] }

        #expect(ids(shown.snapshot?.short) == ["x"])
        #expect(await gallery.authoredAsks == [nil, "a2", "a3"])
    }

    /// A tab whose next page fails says so rather than asking again in a
    /// loop; the viewer's next approach retries.
    @Test func aFailingPageUnderAnEmptyTabWaitsForTheViewer() async {
        let gallery = PagedGallery(authored: [
            nil: GalleryPage(posts: [post("p1", at: 60)], nextPageToken: "a2"),
            "a2": GalleryPage(posts: [post("x", .text, at: 40)], nextPageToken: nil),
        ])
        await gallery.fail("a2")
        let (viewModel, shown) = await open(gallery)

        viewModel.setGalleryFormat(.short)
        await settle {
            if case .failed = shown.snapshot?.short { return true }
            return false
        }
        await settle()
        #expect(await gallery.authoredAsks == [nil, "a2"])

        await gallery.heal("a2")
        viewModel.loadMoreGallery()
        await settle { ids(shown.snapshot?.short) == ["x"] }
        #expect(ids(shown.snapshot?.short) == ["x"])
    }

    /// A revisit or a pull revalidates: the fresh first page goes over the
    /// old one and the pages below it stay.
    @Test func aRevalidationKeepsThePagesBelowTheFirst() async {
        let gallery = PagedGallery(authored: [
            nil: GalleryPage(posts: [post("a", at: 60), post("b", at: 50)], nextPageToken: "a2"),
            "a2": GalleryPage(posts: [post("c", at: 40), post("d", at: 30)], nextPageToken: nil),
        ])
        let (viewModel, shown) = await open(gallery)
        viewModel.setGallerySource(.posts)
        viewModel.loadMoreGallery()
        await settle { ids(shown.snapshot?.activity).count == 4 }

        await gallery.setAuthored(
            GalleryPage(posts: [post("new", at: 70), post("a", at: 60)], nextPageToken: "a2"), for: nil
        )
        viewModel.refresh()
        await settle { ids(shown.snapshot?.activity).first == "new" }

        // "b" slid out of the first page: older than its oldest, kept.
        #expect(ids(shown.snapshot?.activity) == ["new", "a", "b", "c", "d"])
    }

    @Test func mergingAFreshFirstPageOverLaterPages() {
        let shown = [post("gone", at: 65), post("a", at: 60), post("b", at: 50), post("c", at: 40)]
        let fresh = [post("new", at: 70), post("a", at: 60)]

        let merged = ProfileViewModel.mergingGallery(firstPage: fresh, over: shown)

        #expect(merged.map(\.id.rawValue) == ["new", "a", "b", "c"])
    }

    // MARK: - The repository, against the mock

    /// The first request sends a page size, the next ones the token the last
    /// returned, until there is no more: a seeded author's posts, three to a
    /// page, crossing page boundaries without a repeat.
    @Test func theRepositoryFollowsTheTokenThroughAnAuthorsPosts() async throws {
        let dataset = MockSocialDataset()
        let bff = MockBFF()
        MockSocialServices(dataset: dataset).register(on: bff)
        let counters = MockCounterStore(dataset: dataset)
        MockCounterService(store: counters).register(on: bff)
        MockSearchService(dataset: dataset, counters: counters).register(on: bff)
        let client = ConnectClientFactory.makeUnauthenticated(host: "https://mock.bff.local", httpClient: bff)
        func repository(pageLimit: Int32) -> ProfileGalleryRepository {
            ProfileGalleryRepository(
                postClient: Post_V1_PostServiceClient(client: client),
                searchClient: Search_V1_SearchServiceClient(client: client),
                counterClient: Counter_V1_CounterServiceClient(client: client),
                pageLimit: pageLimit
            )
        }
        let byAuthor = Dictionary(grouping: dataset.posts, by: \.authorProfileID)
        let author = try #require(byAuthor.max { $0.value.count < $1.value.count }?.key)
        // What the author's listing holds, in one page the mock can serve.
        let whole = try await repository(pageLimit: 50).authoredPage(for: ProfileID(author), after: nil)
        try #require(whole.posts.count > 3 && whole.nextPageToken == nil)

        let paged = repository(pageLimit: 3)
        var pages = [try await paged.authoredPage(for: ProfileID(author), after: nil)]
        while let token = pages.last?.nextPageToken, pages.count < 50 {
            pages.append(try await paged.authoredPage(for: ProfileID(author), after: token))
        }

        #expect(pages.count == (whole.posts.count + 2) / 3)
        #expect(pages.last?.nextPageToken == nil)
        #expect(pages.flatMap(\.posts).map(\.id) == whole.posts.map(\.id))
    }
}
