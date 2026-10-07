import AuthInterface
import CoreContracts
import CoreModels
import CoreNetworking
import CoreNetworkingMocks
import Foundation
import Testing
@testable import Feed

// The comments stream, page by page (#589).

private struct PagingSessionStub: AuthSessionProviding {
    func currentState() async -> AuthState { .authenticated(AccountID(MockAuthService.accountID)) }
    func stateUpdates() async -> AsyncStream<AuthState> {
        AsyncStream { $0.yield(.authenticated(AccountID(MockAuthService.accountID))); $0.finish() }
    }
    func logout() async {}
}

private final class PagingFeedProvider: FeedProviding, @unchecked Sendable {
    func cachedFirstPage() async -> [FeedEntry]? { nil }
    func loadFirstPage() async throws -> FeedPage { FeedPage(entries: [], nextPageToken: nil, isCold: false) }
    func loadPage(afterToken token: String) async throws -> FeedPage { FeedPage(entries: [], nextPageToken: nil, isCold: false) }
    func loadPost(_ id: PostID) async throws -> FeedEntry {
        FeedEntry(
            post: Post(id: id, authorID: ProfileID("prof-1"), caption: "hi", attachments: [], publishedAt: Date(timeIntervalSince1970: 0)),
            author: AuthorSummary(id: ProfileID("prof-1"), handle: "ava", displayName: "Ava", avatarURL: nil),
            likeCount: 0
        )
    }
}

/// Serves `pages` by token (nil = the first page) and records every ask.
private actor PagedComments: CommentsProviding {
    private var pages: [String?: CommentPage]
    private var failuresLeft: [String: Int] = [:]
    private(set) var requests: [String?] = []

    init(_ pages: [String?: CommentPage]) { self.pages = pages }

    func setPage(_ page: CommentPage, for token: String?) { pages[token] = page }
    func failOnce(_ token: String) { failuresLeft[token] = 1 }

    func loadComments(for postID: PostID) async throws -> [CommentEntry] {
        try await loadCommentsPage(for: postID, after: nil).entries
    }

    func loadCommentsPage(for postID: PostID, after pageToken: String?) async throws -> CommentPage {
        requests.append(pageToken)
        if let token = pageToken, let left = failuresLeft[token], left > 0 {
            failuresLeft[token] = left - 1
            throw CommentsError.transport(message: "offline")
        }
        return pages[pageToken] ?? CommentPage(entries: [], nextPageToken: nil)
    }

    func addComment(_ body: String, to postID: PostID, parentID: String?) async throws -> CommentEntry {
        throw CommentsError.transport(message: "not used")
    }
}

private func entry(_ id: String, at seconds: TimeInterval = 0, parent: String? = nil) -> CommentEntry {
    CommentEntry(
        id: id, authorID: ProfileID("prof-1"), authorName: "Ava", authorHandle: "ava",
        body: id, createdAt: Date(timeIntervalSince1970: seconds), parentID: parent
    )
}

@MainActor
struct CommentsPagingTests {
    /// A ceiling, not a pace — see `PostDetailCommentsTests.settle(until:)`.
    private func settle(until condition: () -> Bool) async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(120))
        while !condition(), ContinuousClock.now < deadline {
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    private func settle(untilAsync condition: () async -> Bool) async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(120))
        while !(await condition()), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    /// Grace for "nothing more should happen".
    private func settle() async {
        await Task.yield()
        try? await Task.sleep(for: .milliseconds(100))
    }

    private final class Shown {
        var ids: [String] = []
        var loaded = false
    }

    private func load(_ provider: PagedComments) async -> (PostDetailViewModel, Shown) {
        let viewModel = PostDetailViewModel(
            postID: PostID("post-1"), repository: PagingFeedProvider(), commentsProvider: provider
        )
        let shown = Shown()
        viewModel.onCommentsChange = {
            guard case .loaded(let models) = $0 else { return }
            shown.ids = models.map(\.id)
            shown.loaded = true
        }
        viewModel.viewDidLoad()
        await settle { shown.loaded }
        return (viewModel, shown)
    }

    // MARK: - The view model

    @Test func nearingTheEndAppendsTheNextPageOnceAndStopsAtTheEnd() async {
        let provider = PagedComments([
            nil: CommentPage(entries: [entry("a"), entry("b")], nextPageToken: "p2"),
            "p2": CommentPage(entries: [entry("c"), entry("d")], nextPageToken: nil),
        ])
        let (viewModel, shown) = await load(provider)
        #expect(shown.ids == ["a", "b"])

        viewModel.loadMoreComments()
        viewModel.loadMoreComments() // the same approach, reported twice
        await settle { shown.ids.count == 4 }
        #expect(shown.ids == ["a", "b", "c", "d"])

        viewModel.loadMoreComments() // the end: nothing left to ask
        await settle()
        #expect(await provider.requests == [nil, "p2"])
    }

    @Test func aPageFilteredToNothingMovesStraightOnToTheNext() async {
        let provider = PagedComments([
            nil: CommentPage(entries: [entry("a")], nextPageToken: "p2"),
            "p2": CommentPage(entries: [], nextPageToken: "p3"),
            "p3": CommentPage(entries: [entry("b")], nextPageToken: nil),
        ])
        let (viewModel, shown) = await load(provider)

        viewModel.loadMoreComments()
        await settle { shown.ids.count == 2 }

        #expect(shown.ids == ["a", "b"])
        #expect(await provider.requests == [nil, "p2", "p3"])
    }

    @Test func aFailedPageKeepsTheStreamAndIsRetriedOnTheNextApproach() async {
        let provider = PagedComments([
            nil: CommentPage(entries: [entry("a")], nextPageToken: "p2"),
            "p2": CommentPage(entries: [entry("b")], nextPageToken: nil),
        ])
        await provider.failOnce("p2")
        let (viewModel, shown) = await load(provider)

        viewModel.loadMoreComments()
        await settle(untilAsync: { await provider.requests.count == 2 })
        await settle()
        #expect(shown.ids == ["a"])

        viewModel.loadMoreComments()
        await settle { shown.ids.count == 2 }
        #expect(shown.ids == ["a", "b"])
    }

    /// A comment on both sides of a page boundary is shown once.
    @Test func aCommentRepeatedAcrossPagesIsShownOnce() async {
        let provider = PagedComments([
            nil: CommentPage(entries: [entry("a"), entry("b")], nextPageToken: "p2"),
            "p2": CommentPage(entries: [entry("b"), entry("c")], nextPageToken: nil),
        ])
        let (viewModel, shown) = await load(provider)

        viewModel.loadMoreComments()
        await settle { shown.ids.count == 3 }

        #expect(shown.ids == ["a", "b", "c"])
    }

    /// Pull-to-refresh with a second page on screen: the first page is
    /// refreshed, the second stays.
    @Test func aRefreshKeepsThePagesBelowTheFirst() async {
        let provider = PagedComments([
            nil: CommentPage(entries: [entry("a", at: 100), entry("b", at: 90)], nextPageToken: "p2"),
            "p2": CommentPage(entries: [entry("c", at: 80), entry("d", at: 70)], nextPageToken: nil),
        ])
        let (viewModel, shown) = await load(provider)
        viewModel.loadMoreComments()
        await settle { shown.ids.count == 4 }

        await provider.setPage(
            CommentPage(entries: [entry("new", at: 110), entry("a", at: 100)], nextPageToken: "p2"), for: nil
        )
        viewModel.refresh()
        await settle { shown.ids.first == "new" }

        #expect(shown.ids == ["new", "a", "b", "c", "d"])
    }

    // MARK: - Pure rules

    /// The fresh first page replaces every thread at least as new as its
    /// oldest — a deleted one goes — and older threads stay, replies and all.
    @Test func mergingAFreshFirstPageOverLaterPages() {
        let shown = [
            entry("x", at: 105), // deleted since
            entry("a", at: 100),
            entry("b", at: 90), entry("b-r", at: 95, parent: "b"),
            entry("c", at: 80),
        ]
        let fresh = [entry("new", at: 110), entry("a", at: 100)]

        let merged = PostDetailViewModel.merging(firstPage: fresh, over: shown)

        #expect(merged.map(\.id) == ["new", "a", "b", "b-r", "c"])
    }

    /// Trending ranks threads within their page: a busy thread arriving with
    /// a later page stays below the rows already on screen.
    @Test func trendingRanksThreadsWithinTheirPage() {
        let entries = [
            entry("a"),
            entry("b"), entry("b-r0", parent: "b"),
            entry("c"), entry("c-r0", parent: "c"), entry("c-r1", parent: "c"),
        ]

        let acrossPages = PostDetailViewModel.sortedForDisplay(entries, order: .trending, liked: [])
        let withinPages = PostDetailViewModel.sortedForDisplay(entries, order: .trending, liked: [], pageStarts: ["c"])

        #expect(acrossPages.filter { $0.parentID == nil }.map(\.id) == ["c", "b", "a"])
        #expect(withinPages.filter { $0.parentID == nil }.map(\.id) == ["b", "a", "c"])
    }

    // MARK: - The repository, against the mock

    /// The first request sends a page size, the next ones the token the
    /// previous page returned, until the server has no more: post-0011's
    /// long conversation, crossing three page boundaries.
    @Test func theRepositoryFollowsTheTokenThroughTheMocksLongConversation() async throws {
        let dataset = MockSocialDataset()
        let bff = MockBFF()
        MockSocialServices(dataset: dataset).register(on: bff)
        MockCommentService(dataset: dataset).register(on: bff)
        let client = ConnectClientFactory.makeUnauthenticated(host: "https://mock.bff.local", httpClient: bff)
        let repository = CommentsRepository(
            commentClient: Comment_V1_CommentServiceClient(client: client),
            profileClient: Profile_V1_ProfileServiceClient(client: client),
            authSession: PagingSessionStub(),
            pageSize: 30
        )
        let post = PostID("post-0011")

        var pages: [CommentPage] = [try await repository.loadCommentsPage(for: post, after: nil)]
        while let token = pages.last?.nextPageToken, pages.count < 10 {
            pages.append(try await repository.loadCommentsPage(for: post, after: token))
        }

        #expect(pages.map(\.entries.count) == [30, 30, 30, 30])
        #expect(pages.last?.nextPageToken == nil)
        let ids = pages.flatMap(\.entries).map(\.id)
        #expect(Set(ids).count == MockCommentService.longConversationCount)
        #expect(ids.first == "post-0011-long-0")
        // Only the first page is the cache the panel mounts from.
        #expect(repository.cachedTopComments(for: post)?.count == 30)
    }
}
