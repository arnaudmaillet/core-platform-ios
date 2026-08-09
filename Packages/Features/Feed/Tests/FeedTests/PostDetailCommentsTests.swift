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

/// Answers `cachedTopComments` synchronously, the way the real repository does
/// once a page has been prefetched.
private final class PrefetchedCommentsProvider: CommentsProviding, @unchecked Sendable {
    private let entries: [CommentEntry]

    init(_ entries: [CommentEntry]) { self.entries = entries }

    nonisolated func cachedTopComments(for postID: PostID) -> [CommentEntry]? { entries }
    func loadComments(for postID: PostID) async throws -> [CommentEntry] { entries }
    func addComment(_ body: String, to postID: PostID, parentID: String?) async throws -> CommentEntry {
        throw CommentsError.transport(message: "not used")
    }
}

private actor StubCommentsProvider: CommentsProviding {
    private var comments: [CommentEntry]
    private(set) var addedBodies: [String] = []
    private(set) var addedParentIDs: [String?] = []

    init(_ comments: [CommentEntry]) { self.comments = comments }

    func loadComments(for postID: PostID) async throws -> [CommentEntry] { comments }

    func addComment(_ body: String, to postID: PostID, parentID: String?) async throws -> CommentEntry {
        addedBodies.append(body)
        addedParentIDs.append(parentID)
        let entry = CommentEntry(
            id: "new", authorID: ProfileID("prof-me"), authorName: "Me", authorHandle: "me",
            body: body, createdAt: Date(timeIntervalSince1970: 100), parentID: parentID
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
    /// process; then 20s losing it again on 2026-07-17 runners — the SAME
    /// test PASSED at 60.8s wall-clock on develop's green run, so a starved
    /// pool can legitimately take a minute end to end). The deadline is a
    /// CEILING, not a pace — success returns immediately, so a fast run pays
    /// nothing (the whole suite is ~1s locally). Returns either way; the
    /// caller's asserts do the judging.
    private func settle(until condition: () -> Bool) async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(120))
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

    private func makeViewModel(_ comments: any CommentsProviding) -> PostDetailViewModel {
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

    /// A reply binds its parent's id through the provider and lands at the
    /// END of that parent's reply block — the thread reads downward — while
    /// its display model carries the level-2 marker.
    @Test func submittingAReplyBindsTheParentAndJoinsItsThread() async {
        let parent = comment("c1", "top")
        let existingReply = CommentEntry(
            id: "c1-r0", authorID: ProfileID("prof-2"), authorName: "Bo", authorHandle: "bo",
            body: "first reply", createdAt: Date(timeIntervalSince1970: 10), parentID: "c1"
        )
        let provider = StubCommentsProvider([parent, existingReply, comment("c2", "second top")])
        let viewModel = makeViewModel(provider)
        var lastComments: PostDetailViewModel.CommentsState?
        viewModel.onCommentsChange = { lastComments = $0 }
        viewModel.viewDidLoad()
        await settle {
            if case .loaded = lastComments { return true } else { return false }
        }

        viewModel.submitComment("agreed!", parentID: "c1")
        await settle {
            if case .loaded(let models) = lastComments { return models.contains { $0.id == "new" } }
            return false
        }

        #expect(await provider.addedParentIDs == ["c1"])
        guard case .loaded(let models) = lastComments else {
            Issue.record("expected loaded")
            return
        }
        // Parent → its replies (existing first, the new one appended) → next top.
        #expect(models.map(\.id) == ["c1", "c1-r0", "new", "c2"])
        #expect(models.first { $0.id == "new" }?.isReply == true)
    }

    /// Trending is THREAD-ranked by the engagement comment.v1 carries
    /// today — reply count plus session likes anywhere in the thread —
    /// stable on ties; Recent restores the repository chronology. Replies
    /// never leave their parents in either order.
    @Test func trendingSortRanksThreadsByEngagement() {
        func entry(_ id: String, parent: String? = nil) -> CommentEntry {
            CommentEntry(
                id: id, authorID: ProfileID("p"), authorName: "A", authorHandle: "a",
                body: "b", createdAt: Date(timeIntervalSince1970: 0), parentID: parent
            )
        }
        let entries = [
            entry("a"),
            entry("b"), entry("b-r0", parent: "b"), entry("b-r1", parent: "b"),
            entry("c"),
        ]
        // Recent: untouched.
        #expect(PostDetailViewModel.sortedForDisplay(entries, order: .recent, liked: []).map(\.id)
            == ["a", "b", "b-r0", "b-r1", "c"])
        // Trending: the 2-reply thread leads; a session like lifts "c"
        // over the bare "a"; replies ride under their parents.
        #expect(PostDetailViewModel.sortedForDisplay(entries, order: .trending, liked: ["c"]).map(\.id)
            == ["b", "b-r0", "b-r1", "c", "a"])
        // A liked reply counts toward ITS thread's score.
        #expect(PostDetailViewModel.sortedForDisplay(entries, order: .trending, liked: ["b-r0"]).map(\.id).first == "b")
    }

    /// The sort selector re-ranks the LIVE stream: switching to Trending
    /// re-emits with the popular thread first; back to Recent restores
    /// chronology. Likes toggle through the view model (one truth) and
    /// deliberately do not re-emit.
    @Test func settingSortReordersTheStream() async {
        let parent = comment("c1", "quiet top")
        let popular = comment("c2", "popular top")
        let reply = CommentEntry(
            id: "c2-r0", authorID: ProfileID("p2"), authorName: "Bo", authorHandle: "bo",
            body: "reply", createdAt: Date(timeIntervalSince1970: 10), parentID: "c2"
        )
        let provider = StubCommentsProvider([parent, popular, reply])
        let viewModel = makeViewModel(provider)
        var emitted: [[String]] = []
        viewModel.onCommentsChange = { state in
            if case .loaded(let models) = state { emitted.append(models.map(\.id)) }
        }
        viewModel.viewDidLoad()
        await settle { !emitted.isEmpty }
        #expect(emitted.last == ["c1", "c2", "c2-r0"])

        let emitsBefore = emitted.count
        #expect(viewModel.toggleCommentLike(commentID: "c1"))
        #expect(viewModel.isCommentLiked("c1"))
        #expect(emitted.count == emitsBefore) // likes never re-emit

        viewModel.setCommentSort(.trending)
        // c2's thread scores 1 (reply); c1 scores 1 (session like) — the
        // tie keeps chronology, so c1 stays first; unlike and re-sort to
        // see the reply-count lead.
        #expect(emitted.last == ["c1", "c2", "c2-r0"])
        _ = viewModel.toggleCommentLike(commentID: "c1") // unlike
        viewModel.setCommentSort(.recent)
        viewModel.setCommentSort(.trending)
        #expect(emitted.last == ["c2", "c2-r0", "c1"])
    }

    /// A first load must ALWAYS report `.loaded`, even when it returns the
    /// same empty list the model started with.
    ///
    /// The stream renders a skeleton until it is told otherwise, so "nothing
    /// changed" and "nothing loaded yet" are the same picture. Suppressing
    /// this emit as a redundant one left every comment-less post skeletal
    /// forever; the suite caught it as a 120-second poll, which is what a
    /// never-satisfied `settle` looks like.
    @Test func anEmptyFirstLoadStillReportsLoaded() async {
        let viewModel = makeViewModel(StubCommentsProvider([]))
        var states: [PostDetailViewModel.CommentsState] = []
        viewModel.onCommentsChange = { states.append($0) }

        viewModel.viewDidLoad()
        await settle {
            if case .loaded = states.last { return true } else { return false }
        }

        #expect(states.contains { if case .loaded(let m) = $0 { return m.isEmpty } else { return false } })
    }

    /// A prefetched first page skips the skeleton entirely: the very first
    /// thing the stream is told is `.loaded`, never `.loading`. That is the
    /// whole point of the cache being synchronous — the panel mounts inside a
    /// layout pass, and anything it awaits is a skeleton on screen.
    @Test func aPrefetchedPageRendersWithoutALoadingState() async {
        let entry = CommentEntry(
            id: "c1", authorID: ProfileID("p1"), authorName: "A", authorHandle: "a",
            body: "hi", createdAt: Date(timeIntervalSince1970: 10), parentID: nil
        )
        let viewModel = makeViewModel(PrefetchedCommentsProvider([entry]))
        var states: [PostDetailViewModel.CommentsState] = []
        viewModel.onCommentsChange = { states.append($0) }

        viewModel.viewDidLoad()

        // Synchronous — no awaiting, which is the contract under test.
        #expect(states.count == 1)
        if case .loaded(let models) = states.first {
            #expect(models.map(\.id) == ["c1"])
        } else {
            Issue.record("first emission was not .loaded: \(String(describing: states.first))")
        }
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
