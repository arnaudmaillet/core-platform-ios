import CoreModels
import Foundation
import Testing
@testable import Feed

private final class PostOnlyFeedProvider: FeedProviding, @unchecked Sendable {
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

private actor StubCommentsProvider: CommentsProviding {
    private var comments: [CommentEntry]
    private(set) var addedBodies: [String] = []

    init(_ comments: [CommentEntry]) { self.comments = comments }

    func loadComments(for postID: PostID) async throws -> [CommentEntry] { comments }

    func addComment(_ body: String, to postID: PostID) async throws -> CommentEntry {
        addedBodies.append(body)
        let entry = CommentEntry(
            id: "new", authorID: ProfileID("prof-me"), authorName: "Me", authorHandle: "me",
            body: body, createdAt: Date(timeIntervalSince1970: 100)
        )
        comments.insert(entry, at: 0)
        return entry
    }
}

private func comment(_ id: String, _ body: String) -> CommentEntry {
    CommentEntry(id: id, authorID: ProfileID("prof-1"), authorName: "Ava", authorHandle: "ava", body: body, createdAt: Date(timeIntervalSince1970: 0))
}

@MainActor
struct PostDetailCommentsTests {
    /// Polls until `condition` holds, up to a generous deadline — CI runners
    /// can starve the cooperative pool far past any fixed sleep (observed: a
    /// 50ms settle losing the race on a hosted runner and reddening
    /// build-test; then a 5s deadline losing the same race once the
    /// shortcut-wheel suite added main-actor UI tests to the parallel
    /// process). The deadline is a CEILING, not a pace — success returns
    /// immediately, so a fast run pays nothing. Returns either way; the
    /// caller's asserts do the judging.
    private func settle(until condition: () -> Bool) async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(20))
        while !condition(), ContinuousClock.now < deadline {
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    /// Fixed grace for negative assertions ("nothing should have happened"),
    /// where there is no positive condition to poll for.
    private func settle() async {
        await Task.yield()
        try? await Task.sleep(for: .milliseconds(100))
    }

    private func makeViewModel(_ comments: StubCommentsProvider) -> PostDetailViewModel {
        PostDetailViewModel(
            postID: PostID("post-1"),
            repository: PostOnlyFeedProvider(),
            commentsProvider: comments
        )
    }

    @Test func loadsCommentsAfterThePost() async {
        let viewModel = makeViewModel(StubCommentsProvider([comment("c1", "nice"), comment("c2", "cool")]))
        var lastComments: PostDetailViewModel.CommentsState?
        viewModel.onCommentsChange = { lastComments = $0 }

        viewModel.viewDidLoad()
        await settle {
            if case .loaded = lastComments { return true } else { return false }
        }

        guard case .loaded(let models) = lastComments else {
            Issue.record("expected loaded comments, got \(String(describing: lastComments))")
            return
        }
        #expect(models.map(\.id) == ["c1", "c2"])
        #expect(models.first?.body == "nice")
    }

    @Test func submittingACommentPrependsItAndCallsProvider() async {
        let provider = StubCommentsProvider([comment("c1", "nice")])
        let viewModel = makeViewModel(provider)
        var lastComments: PostDetailViewModel.CommentsState?
        viewModel.onCommentsChange = { lastComments = $0 }
        viewModel.viewDidLoad()
        await settle {
            if case .loaded = lastComments { return true } else { return false }
        }

        viewModel.submitComment("  my thoughts  ")
        await settle {
            if case .loaded(let models) = lastComments { return models.first?.id == "new" }
            return false
        }

        #expect(await provider.addedBodies == ["my thoughts"]) // trimmed
        guard case .loaded(let models) = lastComments else {
            Issue.record("expected loaded")
            return
        }
        #expect(models.map(\.id) == ["new", "c1"]) // prepended
    }

    @Test func blankCommentIsIgnored() async {
        let provider = StubCommentsProvider([])
        let viewModel = makeViewModel(provider)
        var lastComments: PostDetailViewModel.CommentsState?
        viewModel.onCommentsChange = { lastComments = $0 }
        viewModel.viewDidLoad()
        await settle {
            if case .loaded = lastComments { return true } else { return false }
        }

        viewModel.submitComment("   ")
        await settle() // negative assertion: fixed grace, nothing to poll for

        #expect(await provider.addedBodies.isEmpty)
    }
}
