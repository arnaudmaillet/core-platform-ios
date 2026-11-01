import AuthInterface
import CoreContracts
import CoreModels
import CoreNetworking
import CoreNetworkingMocks
import Foundation
import Testing
@testable import Feed

// The band's later pages (#2005): asked when it runs low, guarded, and
// shared with the comments panel.

private final class NoFeed: FeedProviding, @unchecked Sendable {
    func cachedFirstPage() async -> [FeedEntry]? { nil }
    func loadFirstPage() async throws -> FeedPage { throw FeedError.transport(message: "unused") }
    func loadPage(afterToken token: String) async throws -> FeedPage { throw FeedError.transport(message: "unused") }
    func loadPost(_ id: PostID) async throws -> FeedEntry { throw FeedError.transport(message: "unused") }
}

private func reaction(_ id: String) -> CommentEntry {
    CommentEntry(
        id: id, authorID: ProfileID("prof-1"), authorName: "Ava", authorHandle: "ava",
        body: "GG \(id)", createdAt: Date(timeIntervalSince1970: 1000)
    )
}

/// Three pages of short comments, chained by token; records every ask.
private final class ThreePages: CommentsProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var asked: [String?] = []
    var requests: [String?] { lock.withLock { asked } }

    func loadComments(for postID: PostID) async throws -> [CommentEntry] {
        try await loadCommentsPage(for: postID, after: nil).entries
    }

    func loadCommentsPage(for postID: PostID, after pageToken: String?) async throws -> CommentPage {
        lock.withLock { asked.append(pageToken) }
        switch pageToken {
        case nil: return CommentPage(entries: (0..<10).map { reaction("a\($0)") }, nextPageToken: "p2")
        case "p2": return CommentPage(entries: (0..<10).map { reaction("b\($0)") }, nextPageToken: "p3")
        default: return CommentPage(entries: (0..<10).map { reaction("c\($0)") }, nextPageToken: "p4")
        }
    }

    func addComment(
        _ body: String, to postID: PostID, parentID: String?, commentID: String
    ) async throws -> CommentEntry {
        throw CommentsError.transport(message: "unused")
    }
}

private final class Clock: @unchecked Sendable {
    private let lock = NSLock()
    private var time = Date(timeIntervalSince1970: 0)
    var now: Date { lock.withLock { time } }
    func advance(_ seconds: TimeInterval) { lock.withLock { time += seconds } }
}

@MainActor
struct BandReactionPagesTests {
    private let id = PostID("post-0042")

    private func activate(_ viewModel: FeedViewModel) async {
        await withCheckedContinuation { continuation in
            viewModel.onCommentStreamsChange = { _, _ in
                viewModel.onCommentStreamsChange = nil
                continuation.resume()
            }
            viewModel.pageDidBecomeActive(id)
        }
    }

    private func ranLow(_ viewModel: FeedViewModel) async -> FeedViewModel.CommentStreams {
        await withCheckedContinuation { continuation in
            viewModel.onCommentStreamsChange = { _, streams in
                viewModel.onCommentStreamsChange = nil
                continuation.resume(returning: streams)
            }
            viewModel.bandRanLow(for: id)
        }
    }

    /// A page that lands joins the band's pool, after what it had.
    @Test func aLaterPageJoinsThePool() async {
        let provider = ThreePages()
        let clock = Clock()
        let viewModel = FeedViewModel(repository: NoFeed(), commentsProvider: provider, now: { clock.now })
        await activate(viewModel)
        #expect(viewModel.commentStreams(for: id).reactions.count == 10)

        let streams = await ranLow(viewModel)
        #expect(streams.reactions.map(\.id) == (0..<10).map { "a\($0)" } + (0..<10).map { "b\($0)" })
        #expect(provider.requests == [nil, "p2"])
    }

    /// One page in flight per post: a second ask while it loads is dropped.
    @Test func oneInFlightPerPost() async {
        let provider = ThreePages()
        let clock = Clock()
        let viewModel = FeedViewModel(repository: NoFeed(), commentsProvider: provider, now: { clock.now })
        await activate(viewModel)

        viewModel.bandRanLow(for: id)
        clock.advance(60)
        viewModel.bandRanLow(for: id) // still in flight
        #expect(viewModel.debugReactionPages(for: id).inFlight)
        while viewModel.debugReactionPages(for: id).inFlight { await Task.yield() }
        #expect(provider.requests == [nil, "p2"])
    }

    /// Two pages are at least `reactionPageInterval` apart.
    @Test func theIntervalHoldsTheNextPage() async {
        let provider = ThreePages()
        let clock = Clock()
        let viewModel = FeedViewModel(repository: NoFeed(), commentsProvider: provider, now: { clock.now })
        await activate(viewModel)
        _ = await ranLow(viewModel)

        clock.advance(FeedViewModel.reactionPageInterval - 1)
        viewModel.bandRanLow(for: id)
        #expect(!viewModel.debugReactionPages(for: id).inFlight)

        clock.advance(1)
        _ = await ranLow(viewModel)
        #expect(provider.requests == [nil, "p2", "p3"])
    }

    /// At most `maxExtraReactionPages` past the first; then the band loops.
    @Test func theBandStopsAtTheCap() async {
        let provider = ThreePages()
        let clock = Clock()
        let viewModel = FeedViewModel(repository: NoFeed(), commentsProvider: provider, now: { clock.now })
        await activate(viewModel)
        for _ in 0..<FeedViewModel.maxExtraReactionPages {
            clock.advance(FeedViewModel.reactionPageInterval)
            _ = await ranLow(viewModel)
        }
        clock.advance(FeedViewModel.reactionPageInterval)
        viewModel.bandRanLow(for: id)
        #expect(!viewModel.debugReactionPages(for: id).inFlight)
        #expect(viewModel.debugReactionPages(for: id).fetched == FeedViewModel.maxExtraReactionPages)
        #expect(provider.requests.count == 1 + FeedViewModel.maxExtraReactionPages)
    }

    /// A post with no next page asks nothing.
    @Test func noNextPageAsksNothing() async {
        let provider = FakeOnePage()
        let viewModel = FeedViewModel(repository: NoFeed(), commentsProvider: provider)
        await activate(viewModel)
        viewModel.bandRanLow(for: id)
        #expect(!viewModel.debugReactionPages(for: id).inFlight)
    }
}

private final class FakeOnePage: CommentsProviding, @unchecked Sendable {
    func loadComments(for postID: PostID) async throws -> [CommentEntry] { (0..<10).map { reaction("a\($0)") } }
    func addComment(
        _ body: String, to postID: PostID, parentID: String?, commentID: String
    ) async throws -> CommentEntry {
        throw CommentsError.transport(message: "unused")
    }
}

// MARK: - One pagination for the band and the panel

private struct SignedIn: AuthSessionProviding {
    func currentState() async -> AuthState { .authenticated(AccountID(MockAuthService.accountID)) }
    func stateUpdates() async -> AsyncStream<AuthState> {
        AsyncStream { $0.yield(.authenticated(AccountID(MockAuthService.accountID))); $0.finish() }
    }
    func logout() async {}
}

struct SharedCommentPagesTests {
    /// A page past the first, loaded by either surface, is not asked again
    /// by the other: the repository keeps it for the session.
    @Test func aLaterPageIsFetchedOnce() async throws {
        let dataset = MockSocialDataset()
        let bff = MockBFF()
        MockSocialServices(dataset: dataset).register(on: bff)
        MockCommentService(dataset: dataset).register(on: bff)
        let client = ConnectClientFactory.makeUnauthenticated(host: "https://mock.bff.local", httpClient: bff)
        let repository = CommentsRepository(
            commentClient: Comment_V1_CommentServiceClient(client: client),
            profileClient: Profile_V1_ProfileServiceClient(client: client),
            authSession: SignedIn(),
            pageSize: 30
        )
        let post = PostID("post-0011") // the mock's long conversation: several pages
        let first = try await repository.loadCommentsPage(for: post, after: nil)
        let token = try #require(first.nextPageToken)
        func listCalls() -> Int { bff.recordedRequests.count { $0.path.contains("ListTopLevel") } }
        let before = listCalls()

        let band = try await repository.loadCommentsPage(for: post, after: token)
        let afterBand = listCalls()
        let panel = try await repository.loadCommentsPage(for: post, after: token)

        #expect(afterBand == before + 1)
        #expect(listCalls() == afterBand, "the panel asked the band's page again")
        #expect(panel == band)
    }
}
