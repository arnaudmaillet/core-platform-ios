import AuthInterface
import CoreContracts
import CoreModels
import CoreNetworking
import CoreNetworkingMocks
import Foundation
import Testing
@testable import Feed

// A thread's replies: its two most popular with the page, the rest on
// demand (#637).

private func entry(_ id: String, parent: String? = nil, replyCount: Int? = nil) -> CommentEntry {
    CommentEntry(
        id: id, authorID: ProfileID("prof-1"), authorName: "Ava", authorHandle: "ava",
        body: id, createdAt: Date(timeIntervalSince1970: 0), parentID: parent, replyCount: replyCount
    )
}

private struct ReplySessionStub: AuthSessionProviding {
    func currentState() async -> AuthState { .authenticated(AccountID(MockAuthService.accountID)) }
    func stateUpdates() async -> AsyncStream<AuthState> {
        AsyncStream { $0.yield(.authenticated(AccountID(MockAuthService.accountID))); $0.finish() }
    }
    func logout() async {}
}

private final class ReplyFeedProvider: FeedProviding, @unchecked Sendable {
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

/// One thread "a" with five replies: the page brings two and a cursor, the
/// reply pages are served by token. Records every reply ask; asks can be
/// held until released.
private actor ThreadedComments: CommentsProviding {
    private let firstPage: CommentPage
    private var replyPages: [String?: CommentPage]
    private(set) var replyAsks: [String?] = []
    private var gated = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    init(firstPage: CommentPage, replyPages: [String?: CommentPage]) {
        self.firstPage = firstPage
        self.replyPages = replyPages
    }

    func gate() { gated = true }
    var waitingCount: Int { waiting.count }
    func release() {
        gated = false
        waiting.forEach { $0.resume() }
        waiting = []
    }

    func loadComments(for postID: PostID) async throws -> [CommentEntry] { firstPage.entries }
    func loadCommentsPage(for postID: PostID, after pageToken: String?) async throws -> CommentPage {
        pageToken == nil ? firstPage : CommentPage(entries: [], nextPageToken: nil)
    }

    func loadReplies(for postID: PostID, to parentID: String, after pageToken: String?) async throws -> CommentPage {
        replyAsks.append(pageToken)
        if gated { await withCheckedContinuation { waiting.append($0) } }
        return replyPages[pageToken] ?? CommentPage(entries: [], nextPageToken: nil)
    }

    func addComment(_ body: String, to postID: PostID, parentID: String?, commentID: String) async throws -> CommentEntry {
        CommentEntry(
            id: commentID, authorID: ProfileID("me"), authorName: "Me", authorHandle: "me",
            body: body, createdAt: Date(timeIntervalSince1970: 10), parentID: parentID
        )
    }
}

@MainActor
struct ReplyPagingTests {
    private final class Shown {
        var models: [CommentDisplayModel] = []
        var ids: [String] { models.map(\.id) }
    }

    private func settle(until condition: () async -> Bool) async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(60))
        while !(await condition()), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    private static let page = CommentPage(
        entries: [entry("a", replyCount: 5), entry("a-r4", parent: "a"), entry("a-r3", parent: "a"), entry("b")],
        nextPageToken: nil,
        replyTokens: ["a": "t1"]
    )

    private func load(_ provider: ThreadedComments) async -> (PostDetailViewModel, Shown) {
        let viewModel = PostDetailViewModel(
            postID: PostID("post-1"), repository: ReplyFeedProvider(), commentsProvider: provider
        )
        let shown = Shown()
        viewModel.onCommentsChange = {
            guard case .loaded(let models) = $0 else { return }
            shown.models = models
        }
        viewModel.viewDidLoad()
        await settle { shown.ids.count == 4 && !viewModel.isLoadingFirstPage }
        return (viewModel, shown)
    }

    /// "View 3 more replies" asks for the page after the two shown, appends
    /// it under them, and, the thread all here, the seam folds.
    @Test func expandingLoadsTheNextPagesUntilTheThreadIsWhole() async {
        let provider = ThreadedComments(firstPage: Self.page, replyPages: [
            "t1": CommentPage(entries: [entry("a-r2", parent: "a"), entry("a-r1", parent: "a")], nextPageToken: "t2"),
            "t2": CommentPage(entries: [entry("a-r0", parent: "a")], nextPageToken: nil),
        ])
        let (viewModel, shown) = await load(provider)
        #expect(CommentThreadPresentation.items(from: shown.models, expanded: []).contains(
            .viewMoreReplies(parentID: "a", hiddenCount: 3)
        ))

        viewModel.loadMoreReplies(parentID: "a")
        await settle { shown.ids.count == 6 }
        #expect(shown.ids == ["a", "a-r4", "a-r3", "a-r2", "a-r1", "b"])
        #expect(CommentThreadPresentation.items(from: shown.models, expanded: ["a"]).contains(
            .viewMoreReplies(parentID: "a", hiddenCount: 1)
        ))

        viewModel.loadMoreReplies(parentID: "a")
        await settle { shown.ids.count == 7 }
        #expect(shown.ids == ["a", "a-r4", "a-r3", "a-r2", "a-r1", "a-r0", "b"])
        let expanded = CommentThreadPresentation.items(from: shown.models, expanded: ["a"])
        #expect(expanded.contains(.collapseReplies(parentID: "a")))
        #expect(!expanded.contains { if case .viewMoreReplies = $0 { true } else { false } })

        viewModel.loadMoreReplies(parentID: "a")
        try? await Task.sleep(for: .milliseconds(50))
        #expect(await provider.replyAsks == ["t1", "t2"], "nothing asked once the thread is whole")
    }

    /// Two taps while the page is on its way ask for it once.
    @Test func aPageOnItsWayIsAskedOnce() async {
        let provider = ThreadedComments(firstPage: Self.page, replyPages: [
            "t1": CommentPage(entries: [entry("a-r2", parent: "a")], nextPageToken: nil),
        ])
        let (viewModel, shown) = await load(provider)
        await provider.gate()

        viewModel.loadMoreReplies(parentID: "a")
        viewModel.loadMoreReplies(parentID: "a")
        await settle { await provider.waitingCount == 1 }
        await provider.release()
        await settle { shown.ids.count == 5 }

        #expect(await provider.replyAsks == ["t1"])
    }

    /// The server ranks again for each page: a reply already shown comes back
    /// once, and a page of nothing new asks for the next.
    @Test func aReplyThatComesBackIsShownOnce() async {
        let provider = ThreadedComments(firstPage: Self.page, replyPages: [
            "t1": CommentPage(entries: [entry("a-r3", parent: "a")], nextPageToken: "t2"),
            "t2": CommentPage(entries: [entry("a-r4", parent: "a"), entry("a-r2", parent: "a")], nextPageToken: "t3"),
        ])
        let (viewModel, shown) = await load(provider)

        viewModel.loadMoreReplies(parentID: "a")
        await settle { shown.ids.count == 5 }

        #expect(shown.ids == ["a", "a-r4", "a-r3", "a-r2", "b"])
        #expect(await provider.replyAsks == ["t1", "t2"])
    }

    /// The viewer's reply joins the thread's count, so "View N more" does
    /// not count it among the ones not shown.
    @Test func theViewersReplyCountsInItsThread() async {
        let provider = ThreadedComments(firstPage: Self.page, replyPages: [:])
        let (viewModel, shown) = await load(provider)

        viewModel.submitComment("mine", parentID: "a")
        await settle { shown.ids.count == 5 }

        #expect(shown.models.first { $0.id == "a" }?.replyCount == 6)
        #expect(CommentThreadPresentation.items(from: shown.models, expanded: ["a"]).contains(
            .viewMoreReplies(parentID: "a", hiddenCount: 3)
        ))
    }
}

// MARK: - Presentation

struct ReplyCountPresentationTests {
    private func model(_ id: String, parent: String? = nil, replyCount: Int? = nil) -> CommentDisplayModel {
        CommentDisplayModel(entry: entry(id, parent: parent, replyCount: replyCount))
    }

    /// The seam counts from the server's reply count, not from what loaded.
    @Test func theSeamCountsTheServersReplies() {
        let models = [model("a", replyCount: 9), model("a-r0", parent: "a"), model("a-r1", parent: "a"), model("b", replyCount: 0)]

        #expect(CommentThreadPresentation.items(from: models, expanded: []) == [
            .comment(models[0]), .comment(models[1]), .comment(models[2]),
            .viewMoreReplies(parentID: "a", hiddenCount: 7),
            .comment(models[3]),
        ])
        // Opened while its next page is on the way: still the same count.
        #expect(CommentThreadPresentation.items(from: models, expanded: ["a"]).last(where: {
            if case .viewMoreReplies = $0 { true } else { false }
        }) == .viewMoreReplies(parentID: "a", hiddenCount: 7))
    }

    /// One reply loaded of one: no seam at all.
    @Test func aWholeShortThreadHasNoSeam() {
        let models = [model("a", replyCount: 1), model("a-r0", parent: "a")]
        #expect(CommentThreadPresentation.items(from: models, expanded: []) == [.comment(models[0]), .comment(models[1])])
    }
}

// MARK: - The repository against the mock

struct ReplyRepositoryTests {
    private func makeRepository(likes: MockCounterStore, replyPageSize: Int32 = 20) -> CommentsRepository {
        let dataset = MockSocialDataset()
        let bff = MockBFF()
        MockSocialServices(dataset: dataset).register(on: bff)
        MockCommentService(dataset: dataset, likeCount: { likes.likeCount(target: "comment:" + $0) }).register(on: bff)
        let client = ConnectClientFactory.makeUnauthenticated(host: "https://mock.bff.local", httpClient: bff)
        return CommentsRepository(
            commentClient: Comment_V1_CommentServiceClient(client: client),
            profileClient: Profile_V1_ProfileServiceClient(client: client),
            authSession: ReplySessionStub(),
            replyPageSize: replyPageSize
        )
    }

    /// The page carries each thread's two most liked replies (ties to the
    /// newest) and its count; "View more" continues from the cursor in the
    /// same order, crossing page boundaries, until the thread is whole.
    @Test func aThreadOpensOnItsMostLikedRepliesAndPagesTheRest() async throws {
        let likes = MockCounterStore(dataset: MockSocialDataset())
        likes.stake(3, account: "acct-x", target: "comment:post-0006-sem-0-r0")
        likes.stake(1, account: "acct-x", target: "comment:post-0006-sem-0-r2")
        let repository = makeRepository(likes: likes, replyPageSize: 2)
        let post = PostID("post-0006")
        let parent = "post-0006-sem-0"

        let page = try await repository.loadCommentsPage(for: post, after: nil)
        let shown = page.entries.filter { $0.parentID == parent }.map(\.id)
        #expect(shown == ["\(parent)-r0", "\(parent)-r2"])
        #expect(page.entries.first { $0.id == parent }?.replyCount == 6)
        let cursor = try #require(page.replyTokens[parent])

        var rest: [String] = []
        var token: String? = cursor
        while let next = token {
            let replies = try await repository.loadReplies(for: post, to: parent, after: next)
            rest += replies.entries.map(\.id)
            token = replies.nextPageToken
        }
        // The rest, newest first: r5, r4, r3, r1.
        #expect(rest == ["\(parent)-r5", "\(parent)-r4", "\(parent)-r3", "\(parent)-r1"])
    }

    /// A thread with no replies is not asked for any.
    @Test func aThreadWithoutRepliesCarriesNoCursor() async throws {
        let repository = makeRepository(likes: MockCounterStore(dataset: MockSocialDataset()))
        let page = try await repository.loadCommentsPage(for: PostID("post-0001"), after: nil)

        #expect(page.entries.allSatisfy { $0.replyCount == 0 && $0.parentID == nil })
        #expect(page.replyTokens.isEmpty)
    }
}
