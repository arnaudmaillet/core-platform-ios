import Connect
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

private func repost(_ id: String, at ms: Int64) -> GalleryPost {
    GalleryPost(id: PostID(id), kind: .photo, isRepost: true, thumbnailURL: nil, caption: id, publishedAtMS: ms)
}

private struct GalleryStubError: Error {}

/// Serves each corpus's pages by token (nil = the first) and records every ask.
private actor PagedGallery: ProfileGalleryProviding {
    private var authored: [String?: GalleryPage]
    private var tagged: [String?: GalleryPage]
    private var failing: [String: any Error] = [:]
    /// What the authored FIRST page throws, if anything (#794).
    private var firstPageError: (any Error)?
    private(set) var authoredAsks: [String?] = []
    private(set) var taggedAsks: [String?] = []

    init(authored: [String?: GalleryPage], tagged: [String?: GalleryPage] = [nil: GalleryPage(posts: [], nextPageToken: nil)]) {
        self.authored = authored
        self.tagged = tagged
    }

    func setAuthored(_ page: GalleryPage, for token: String?) { authored[token] = page }
    func fail(_ token: String, with error: any Error = GalleryStubError()) { failing[token] = error }
    func heal(_ token: String) { failing[token] = nil }
    func failFirstPage(with error: any Error) { firstPageError = error }

    func authoredPage(for profileID: ProfileID, after pageToken: String?) async throws -> GalleryPage {
        authoredAsks.append(pageToken)
        if pageToken == nil, let firstPageError { throw firstPageError }
        if let pageToken, let error = failing[pageToken] { throw error }
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

    /// Waits for STATE, counted in looks rather than wall-clock time — the
    /// pattern of Profile's other suites (`FollowRequestsTests`). A loaded CI
    /// runner can freeze this process for longer than any deadline: a
    /// wall-clock budget then expires while the wait never even ran, and the
    /// test reads the screen before the view model has published (#636's
    /// first run). A frozen process spends no looks. The waits the rest of a
    /// test stands on are `#require`d, so a wait that gives up says so.
    @discardableResult
    private func settle(until condition: () async -> Bool) async -> Bool {
        for _ in 0..<2_000 {
            await Task.yield()
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return await condition()
    }

    /// Grace for "nothing more should happen".
    private func settle() async {
        try? await Task.sleep(for: .milliseconds(150))
    }

    private func ids(_ state: ProfileViewModel.GalleryPageState?) -> [String] {
        guard case .content(let posts) = state else { return [] }
        return posts.map(\.id.rawValue)
    }

    /// Your own profile by default; its pages are its sources since #772, as
    /// anyone else's since #696.
    private func open(
        _ gallery: PagedGallery, source: ProfileViewModel.Source = .currentUser
    ) async throws -> (ProfileViewModel, Shown) {
        let viewModel = ProfileViewModel(repository: OneProfile(), gallery: gallery, source: source)
        let shown = Shown()
        viewModel.onGalleryChange = { shown.snapshot = $0 }
        viewModel.viewDidLoad()
        try #require(await settle {
            if case .loading = shown.snapshot?.activity { return false }
            return shown.snapshot != nil
        })
        return (viewModel, shown)
    }

    @Test func nearingTheEndAppendsTheNextPageOnceAndStopsAtTheEnd() async throws {
        let gallery = PagedGallery(authored: [
            nil: GalleryPage(posts: [post("a", at: 60), post("b", at: 50)], nextPageToken: "a2"),
            "a2": GalleryPage(posts: [post("c", at: 40)], nextPageToken: nil),
        ])
        let (viewModel, shown) = try await open(gallery)
        #expect(ids(shown.snapshot?.activity) == ["a", "b"])

        viewModel.loadMoreGallery()
        viewModel.loadMoreGallery() // the same approach, reported twice
        try #require(await settle { ids(shown.snapshot?.activity).count == 3 })
        #expect(ids(shown.snapshot?.activity) == ["a", "b", "c"])

        viewModel.loadMoreGallery() // the end: nothing left to ask
        await settle()
        #expect(await gallery.authoredAsks == [nil, "a2"])
    }

    /// ⚠️ SOMEONE ELSE'S REPOSTS PAGE PAGES THROUGH A RUN OF PLAIN POSTS
    /// (#696): Posts and Reposts split one authored cursor, and pages of
    /// plain posts add nothing to Reposts — so, on screen, it keeps asking
    /// until a repost arrives, rather than stalling empty.
    @Test func aRepostsPageKeepsPagingPastPlainPosts() async throws {
        let gallery = PagedGallery(authored: [
            nil: GalleryPage(posts: [post("a", at: 100), post("b", at: 90)], nextPageToken: "a2"),
            "a2": GalleryPage(posts: [post("c", at: 80), post("d", at: 70)], nextPageToken: "a3"),
            "a3": GalleryPage(posts: [post("e", at: 60)], nextPageToken: "a4"),
            "a4": GalleryPage(posts: [repost("r", at: 50)], nextPageToken: nil),
        ])
        let (viewModel, shown) = try await open(gallery, source: .profile(ProfileID("prof-1")))
        #expect(ids(shown.snapshot?.activity) == ["a", "b"])

        viewModel.setActiveTab(.reposts)
        try #require(await settle { ids(shown.snapshot?.reposts) == ["r"] })
        #expect(await gallery.authoredAsks == [nil, "a2", "a3", "a4"])
        #expect(shown.snapshot?.repostsComplete == true)
        // Posts kept every plain post the run brought, reposts excluded.
        #expect(ids(shown.snapshot?.activity) == ["a", "b", "c", "d", "e"])
    }

    /// The media gallery "View all" pushes (#631) shows only media: a page
    /// of text posts adds nothing to it, and with no tile coming on screen to
    /// ask, the next page is asked at once.
    @Test func aListThatAPageLeavesUnchangedKeepsLoading() async throws {
        let gallery = PagedGallery(authored: [
            nil: GalleryPage(posts: [post("t1", .text, at: 60)], nextPageToken: "a2"),
            "a2": GalleryPage(posts: [post("t2", .text, at: 50)], nextPageToken: "a3"),
            "a3": GalleryPage(posts: [post("x", at: 40)], nextPageToken: nil),
        ])
        let (viewModel, shown) = try await open(gallery)

        viewModel.setGalleryFormat(.media)
        try #require(await settle { ids(shown.snapshot?.media) == ["x"] })

        #expect(ids(shown.snapshot?.media) == ["x"])
        #expect(await gallery.authoredAsks == [nil, "a2", "a3"])
    }

    /// A tab whose next page fails says so rather than asking again in a
    /// loop; the viewer's next approach retries.
    @Test func aFailingPageUnderAnEmptyTabWaitsForTheViewer() async throws {
        let gallery = PagedGallery(authored: [
            nil: GalleryPage(posts: [post("t1", .text, at: 60)], nextPageToken: "a2"),
            "a2": GalleryPage(posts: [post("x", at: 40)], nextPageToken: nil),
        ])
        await gallery.fail("a2")
        let (viewModel, shown) = try await open(gallery)

        viewModel.setGalleryFormat(.media)
        try #require(await settle {
            if case .failed = shown.snapshot?.media { return true }
            return false
        })
        await settle()
        #expect(await gallery.authoredAsks == [nil, "a2"])

        await gallery.heal("a2")
        viewModel.loadMoreGallery()
        try #require(await settle { ids(shown.snapshot?.media) == ["x"] })
        #expect(ids(shown.snapshot?.media) == ["x"])
    }

    // MARK: - Why a page failed (#794)

    /// The fetches used to be `try?`: offline read "Couldn't load" like any
    /// other failure.
    @Test func anOfflineFirstPageSaysOffline() async throws {
        let gallery = PagedGallery(authored: [:])
        await gallery.failFirstPage(with: ProfileError.transport(message: "x", failure: .offline))
        let (_, shown) = try await open(gallery)
        #expect(shown.snapshot?.activity == .failed(message: FailureCopy.offline))
    }

    @Test func aServerFaultOnTheFirstPageKeepsThePullToRetry() async throws {
        let gallery = PagedGallery(authored: [:])
        await gallery.failFirstPage(with: ProfileError.transport(message: "x", failure: .server(code: "internal")))
        let (_, shown) = try await open(gallery)
        #expect(shown.snapshot?.activity == .failed(message: "Couldn't load. Pull to retry."))
    }

    @Test func anOfflineNextPageUnderAnEmptyTabSaysOffline() async throws {
        let gallery = PagedGallery(authored: [
            nil: GalleryPage(posts: [post("t1", .text, at: 60)], nextPageToken: "a2"),
        ])
        await gallery.fail("a2", with: ConnectError(
            code: .unavailable, message: "x", exception: URLError(.notConnectedToInternet)
        ))
        let (viewModel, shown) = try await open(gallery)

        viewModel.setGalleryFormat(.media)
        try #require(await settle {
            if case .failed = shown.snapshot?.media { return true }
            return false
        })
        #expect(shown.snapshot?.media == .failed(message: FailureCopy.offline))
    }

    /// A revisit or a pull revalidates: the fresh first page goes over the
    /// old one and the pages below it stay.
    @Test func aRevalidationKeepsThePagesBelowTheFirst() async throws {
        let gallery = PagedGallery(authored: [
            nil: GalleryPage(posts: [post("a", at: 60), post("b", at: 50)], nextPageToken: "a2"),
            "a2": GalleryPage(posts: [post("c", at: 40), post("d", at: 30)], nextPageToken: nil),
        ])
        let (viewModel, shown) = try await open(gallery)
        viewModel.loadMoreGallery()
        try #require(await settle { ids(shown.snapshot?.activity).count == 4 })

        await gallery.setAuthored(
            GalleryPage(posts: [post("new", at: 70), post("a", at: 60)], nextPageToken: "a2"), for: nil
        )
        viewModel.refresh()
        try #require(await settle { ids(shown.snapshot?.activity).first == "new" })

        // "b" slid out of the first page: older than its oldest, kept.
        #expect(ids(shown.snapshot?.activity) == ["new", "a", "b", "c", "d"])
    }

    // MARK: - A feed opened from the grid going on (#638)

    /// What the grid holds past a post, then its next page, then the end.
    @Test func aFeedFromTheGridGoesOnIntoItsNextPages() async throws {
        let gallery = PagedGallery(authored: [
            nil: GalleryPage(posts: [post("a", at: 60), post("b", at: 50)], nextPageToken: "a2"),
            "a2": GalleryPage(posts: [post("c", at: 40)], nextPageToken: nil),
        ])
        let (viewModel, shown) = try await open(gallery)

        #expect(await viewModel.galleryPostIDs(after: PostID("a")) == [PostID("b")])
        #expect(await viewModel.galleryPostIDs(after: PostID("b")) == [PostID("c")])
        #expect(await viewModel.galleryPostIDs(after: PostID("c")) == nil)
        // The grid paged with the feed: the post it reached is a tile too.
        #expect(ids(shown.snapshot?.activity) == ["a", "b", "c"])
        #expect(await gallery.authoredAsks == [nil, "a2"])
    }

    /// A failed page is "nothing yet": the feed keeps its place.
    @Test func aFeedFromTheGridHearsNothingYetOnAFailure() async throws {
        let gallery = PagedGallery(authored: [
            nil: GalleryPage(posts: [post("a", at: 60)], nextPageToken: "a2"),
            "a2": GalleryPage(posts: [post("b", at: 50)], nextPageToken: nil),
        ])
        await gallery.fail("a2")
        let (viewModel, _) = try await open(gallery)

        #expect(await viewModel.galleryPostIDs(after: PostID("a")) == [])

        await gallery.heal("a2")
        #expect(await viewModel.galleryPostIDs(after: PostID("a")) == [PostID("b")])
    }

    @Test func mergingAFreshFirstPageOverLaterPages() {
        let shown = [post("gone", at: 65), post("a", at: 60), post("b", at: 50), post("c", at: 40)]
        let fresh = [post("new", at: 70), post("a", at: 60)]

        let merged = ProfileGalleryStore.mergingGallery(firstPage: fresh, over: shown)

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
