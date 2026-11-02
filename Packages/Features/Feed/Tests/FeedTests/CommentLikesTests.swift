import AuthInterface
import CoreContracts
import CoreModels
import CoreNetworking
import CoreNetworkingMocks
import Foundation
import Testing
@testable import Feed

// Comment likes are point stakes, like a post's (#637).

private final class LikesFeedProvider: FeedProviding, @unchecked Sendable {
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

private actor LikesComments: CommentsProviding {
    let entries: [CommentEntry]
    init(_ entries: [CommentEntry]) { self.entries = entries }
    func loadComments(for postID: PostID) async throws -> [CommentEntry] { entries }
    func addComment(_ body: String, to postID: PostID, parentID: String?, commentID: String) async throws -> CommentEntry {
        throw CommentsError.transport(message: "not used")
    }
}

/// Serves comment likes from a table; a like adds a point unless refused,
/// and can be held until released.
private final class FakeCommentLikes: EngagementProviding, CommentLiking, @unchecked Sendable {
    private let lock = NSLock()
    private var table: [String: CommentLikes]
    private var refusing = false
    private var holding = false
    private(set) var likeCalls: [String] = []
    private(set) var reads: [[String]] = []

    init(_ table: [String: CommentLikes]) { self.table = table }

    func refuse() { lock.withLock { refusing = true } }
    func hold() { lock.withLock { holding = true } }
    func release() { lock.withLock { holding = false } }
    var calls: [String] { lock.withLock { likeCalls } }
    var readCount: Int { lock.withLock { reads.count } }

    func like(_ postID: PostID) async throws {}
    func likeCounts(for postIDs: [PostID]) async throws -> [PostID: Int64] { [:] }

    func likeComment(_ commentID: String) async throws {
        lock.withLock { likeCalls.append(commentID) }
        for _ in 0..<6_000 where lock.withLock({ holding }) {
            try await Task.sleep(for: .milliseconds(5))
        }
        if lock.withLock({ refusing }) { throw LikeRefused(outcome: .ownContent) }
        lock.withLock {
            let now = table[commentID] ?? CommentLikes(count: 0, mine: 0)
            table[commentID] = CommentLikes(count: now.count + 1, mine: now.mine + 1)
        }
    }

    func commentLikes(for commentIDs: [String]) async throws -> [String: CommentLikes] {
        lock.withLock {
            reads.append(commentIDs)
            return table.filter { commentIDs.contains($0.key) }
        }
    }
}

private func comment(_ id: String, parent: String? = nil, at seconds: TimeInterval = 0) -> CommentEntry {
    CommentEntry(
        id: id, authorID: ProfileID("prof-1"), authorName: "Ava", authorHandle: "ava",
        body: id, createdAt: Date(timeIntervalSince1970: seconds), parentID: parent
    )
}

@MainActor
struct CommentLikesTests {
    private final class Shown {
        var models: [CommentDisplayModel] = []
        var emits = 0
        var ids: [String] { models.map(\.id) }
        func model(_ id: String) -> CommentDisplayModel? { models.first { $0.id == id } }
    }

    /// A look budget, not a wall-clock deadline: a starved runner sleeps
    /// longer per look and so waits longer; every positive wait is expected.
    private func settle(until condition: () -> Bool) async -> Bool {
        for _ in 0..<6_000 {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    private func load(_ comments: [CommentEntry], likes: FakeCommentLikes) async -> (PostDetailViewModel, Shown) {
        let viewModel = PostDetailViewModel(
            postID: PostID("post-1"), repository: LikesFeedProvider(),
            engagementProvider: likes, commentsProvider: LikesComments(comments)
        )
        let shown = Shown()
        viewModel.onCommentsChange = {
            guard case .loaded(let models) = $0 else { return }
            shown.models = models
            shown.emits += 1
        }
        viewModel.viewDidLoad()
        #expect(await settle { shown.ids.count == comments.count && likes.readCount > 0 })
        return (viewModel, shown)
    }

    /// The comments' likes come from the server: count and the viewer's own.
    @Test func theRowsShowTheServersLikes() async {
        let likes = FakeCommentLikes(["a": CommentLikes(count: 12, mine: 2), "b": CommentLikes(count: 3, mine: 0)])
        // Kept alive to the end: a view model let go drops the read that
        // lands after it (`[weak self]`).
        let (viewModel, shown) = await load([comment("a"), comment("b")], likes: likes)
        defer { withExtendedLifetime(viewModel) {} }

        #expect(
            await settle { shown.model("a")?.likeCount == 12 },
            "shown \(shown.models.map { "\($0.id)=\($0.likeCount)" }) reads \(likes.reads) emits \(shown.emits)"
        )
        #expect(shown.model("a")?.isLiked == true)
        #expect(shown.model("b")?.likeCount == 3)
        #expect(shown.model("b")?.isLiked == false)
    }

    /// A tap stakes a point: shown at once, and it stays once it lands.
    @Test func aLikeIsAPointShownAtOnce() async {
        let likes = FakeCommentLikes(["a": CommentLikes(count: 4, mine: 0)])
        let (viewModel, shown) = await load([comment("a")], likes: likes)
        #expect(await settle { shown.model("a")?.likeCount == 4 })
        likes.hold()

        // Taken: the screen plays `toggleOn` on this answer (#1885).
        #expect(viewModel.likeComment(commentID: "a"))
        #expect(shown.model("a")?.likeCount == 5)
        #expect(shown.model("a")?.isLiked == true)
        // One in flight per comment: a second tap meanwhile asks nothing,
        // and plays nothing.
        #expect(!viewModel.likeComment(commentID: "a"))
        likes.release()
        #expect(await settle { likes.calls.count == 1 })
        try? await Task.sleep(for: .milliseconds(50))

        #expect(likes.calls == ["a"])
        #expect(shown.model("a")?.likeCount == 5)
    }

    /// A refused like (one's own comment) is taken back.
    @Test func aRefusedLikeIsTakenBack() async {
        let likes = FakeCommentLikes(["a": CommentLikes(count: 4, mine: 0)])
        let (viewModel, shown) = await load([comment("a")], likes: likes)
        #expect(await settle { shown.model("a")?.likeCount == 4 })
        likes.refuse()

        viewModel.likeComment(commentID: "a")
        #expect(shown.model("a")?.likeCount == 5)

        #expect(await settle { shown.model("a")?.likeCount == 4 })
        #expect(shown.model("a")?.isLiked == false)
    }

    /// Likes are read once per comment, and again for the comments a later
    /// emission brings.
    @Test func eachCommentsLikesAreReadOnce() async {
        let likes = FakeCommentLikes(["a": CommentLikes(count: 1, mine: 0)])
        let (viewModel, shown) = await load([comment("a"), comment("b")], likes: likes)
        #expect(await settle { shown.model("a")?.likeCount == 1 })

        try? await Task.sleep(for: .milliseconds(50))

        #expect(likes.reads.count == 1)
        #expect(Set(likes.reads.first ?? []) == ["a", "b"])
    }
}

// MARK: - Against the mock

private struct LikesSessionStub: AuthSessionProviding {
    func currentState() async -> AuthState { .authenticated(AccountID(MockAuthService.accountID)) }
    func stateUpdates() async -> AsyncStream<AuthState> {
        AsyncStream { $0.yield(.authenticated(AccountID(MockAuthService.accountID))); $0.finish() }
    }
    func logout() async {}
}

private struct LikesMemberToken: AuthTokenProviding {
    func validAccessToken() async throws -> String? { "at-1" }
}

struct CommentLikesRepositoryTests {
    /// A comment like is a point staked through `wallet.Stake` on the
    /// comment; `BatchGetLikes` reads back the count and the viewer's own,
    /// and the mock's replies rank by it — the popularity order moves.
    @Test func aCommentLikeIsAStakeThatMovesThePopularityOrder() async throws {
        let dataset = MockSocialDataset()
        let bff = MockBFF()
        let store = MockCounterStore(dataset: dataset)
        MockSocialServices(dataset: dataset).register(on: bff)
        MockEngagementService(store: store).register(on: bff)
        MockWalletService(store: store, dataset: dataset).register(on: bff)
        MockCommentService(dataset: dataset, likeCount: { store.likeCount(target: "comment:" + $0) }).register(on: bff)
        let client = ConnectClientFactory.makeAuthenticated(
            host: "https://mock.bff.local", tokenProvider: LikesMemberToken(), httpClient: bff
        )
        let session = LikesSessionStub()
        let viewer = ViewerSession(authSession: session) { account in
            try await AccountProfilesReader.profileIDs(
                ofAccount: account.rawValue, using: Profile_V1_ProfileServiceClient(client: client)
            ).map { ProfileID($0) }
        }
        let feed = FeedRepository(
            timelineClient: Timeline_V1_TimelineServiceClient(client: client),
            postClient: Post_V1_PostServiceClient(client: client),
            profileClient: Profile_V1_ProfileServiceClient(client: client),
            counterClient: Counter_V1_CounterServiceClient(client: client),
            engagementClient: Engagement_V1_EngagementServiceClient(client: client),
            likeStaking: WalletLikeStaking(walletClient: Wallet_V1_WalletServiceClient(client: client), viewer: viewer),
            authSession: session,
            viewer: viewer,
            localCache: nil
        )
        let comments = CommentsRepository(
            commentClient: Comment_V1_CommentServiceClient(client: client),
            profileClient: Profile_V1_ProfileServiceClient(client: client),
            authSession: session,
            viewer: viewer
        )
        let post = PostID("post-0006")
        let parent = "post-0006-sem-0"
        let oldest = "\(parent)-r0"
        let before = try await comments.loadCommentsPage(for: post, after: nil)
        #expect(!before.entries.contains { $0.id == oldest }, "the oldest reply is not among the two shown")

        try await feed.likeComment(oldest)
        try await feed.likeComment(oldest)

        let read = try await feed.commentLikes(for: [oldest, "\(parent)-r1"])
        #expect(read[oldest] == CommentLikes(count: 2, mine: 2))
        #expect(read["\(parent)-r1"] == CommentLikes(count: 0, mine: 0))
        let after = try await comments.loadCommentsPage(for: post, after: nil)
        #expect(after.entries.filter { $0.parentID == parent }.first?.id == oldest)
        #expect(bff.recordedRequests.contains { $0.path == "/wallet.v1.WalletService/Stake" })
    }
}
