import CoreModels
import Foundation
import Testing
@testable import Feed

private final class PopularFeedProvider: FeedProviding, @unchecked Sendable {
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

private func comment(_ id: String, parent: String? = nil, by author: String = "prof-2") -> CommentEntry {
    CommentEntry(
        id: id, authorID: ProfileID(author), authorName: "Someone", authorHandle: "someone",
        body: "comment \(id)", createdAt: Date(timeIntervalSince1970: 0), parentID: parent
    )
}

/// Recent newest first; Popular ranked, in two pages that overlap (the
/// ranking is read again per page).
private actor RankedComments: CommentsProviding {
    private(set) var asked: [(token: String?, ranked: Bool)] = []
    /// Past `CommentSortPolicy`'s threshold, so the Popular tab exists.
    func loadComments(for postID: PostID) async throws -> [CommentEntry] {
        [comment("c3"), comment("c2"), comment("c1")] + (4...12).map { comment("r\($0)") }
    }
    func loadCommentsPage(for postID: PostID, after pageToken: String?) async throws -> CommentPage {
        asked.append((pageToken, false))
        return CommentPage(entries: try await loadComments(for: postID), nextPageToken: nil)
    }
    func loadCommentsPage(for postID: PostID, after pageToken: String?, order: CommentSortOrder) async throws -> CommentPage {
        guard order != .recent else { return try await loadCommentsPage(for: postID, after: pageToken) }
        asked.append((pageToken, true))
        return pageToken == nil
            ? CommentPage(entries: [comment("c2"), comment("c1")], nextPageToken: "p2")
            : CommentPage(entries: [comment("c1"), comment("c3")], nextPageToken: nil)
    }
    func addComment(_ body: String, to postID: PostID, parentID: String?, commentID: String) async throws -> CommentEntry {
        comment(commentID, parent: parentID, by: "prof-viewer")
    }
}

private actor FewComments: CommentsProviding {
    private(set) var rankedAsks = 0
    func loadComments(for postID: PostID) async throws -> [CommentEntry] { [comment("a"), comment("b")] }
    func loadCommentsPage(for postID: PostID, after pageToken: String?, order: CommentSortOrder) async throws -> CommentPage {
        if order != .recent { rankedAsks += 1 }
        return CommentPage(entries: try await loadComments(for: postID), nextPageToken: nil)
    }
    func addComment(_ body: String, to postID: PostID, parentID: String?, commentID: String) async throws -> CommentEntry {
        comment(commentID)
    }
}

/// The Popular tab's stream (#2007): the server's ranking beside Recent's.
@MainActor
struct PopularCommentsStreamTests {
    private final class Shown {
        var recent: [String] = []
        var popular: [String]?
    }

    private func settle(until condition: () -> Bool) async -> Bool {
        for _ in 0..<3_000 {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return condition()
    }

    private func load() async -> (PostDetailViewModel, Shown, RankedComments) {
        let provider = RankedComments()
        let viewModel = PostDetailViewModel(
            postID: PostID("post-1"), repository: PopularFeedProvider(), commentsProvider: provider
        )
        let shown = Shown()
        viewModel.onCommentsChange = { if case .loaded(let models) = $0 { shown.recent = models.map(\.id) } }
        viewModel.onPopularCommentsChange = { if case .loaded(let models) = $0 { shown.popular = models.map(\.id) } }
        viewModel.viewDidLoad()
        return (viewModel, shown, provider)
    }

    /// Popular loads right after Recent's first page, in the server's order.
    @Test func popularLoadsAfterRecentInTheServersOrder() async {
        let (viewModel, shown, provider) = await load()
        defer { withExtendedLifetime(viewModel) {} }
        #expect(await settle { shown.popular != nil })
        #expect(Array(shown.recent.prefix(3)) == ["c3", "c2", "c1"])
        #expect(shown.popular == ["c2", "c1"])
        let asked = await provider.asked
        #expect(asked.first.map { !$0.ranked } == true, "Popular asked before Recent")
        #expect(asked.contains { $0.ranked && $0.token == nil })
    }

    /// Its next page lands below, without the ids already shown.
    @Test func popularPagesDownwardWithoutDuplicates() async {
        let (viewModel, shown, _) = await load()
        defer { withExtendedLifetime(viewModel) {} }
        #expect(await settle { shown.popular != nil })
        viewModel.loadMorePopularComments()
        #expect(await settle { shown.popular == ["c2", "c1", "c3"] }, "\(String(describing: shown.popular))")
    }

    /// A comment the viewer sends leads Popular as theirs, and lands in
    /// Recent too; the tab does not change.
    @Test func aSentCommentLeadsPopularAndLandsInRecent() async {
        let (viewModel, shown, _) = await load()
        defer { withExtendedLifetime(viewModel) {} }
        #expect(await settle { shown.popular != nil })
        viewModel.submitComment("mine")
        #expect(await settle { shown.popular?.count == 3 })
        let mine = shown.popular?.first
        #expect(mine != nil && mine != "c2", "the viewer's comment does not lead Popular")
        #expect(shown.recent.contains(mine ?? ""), "it is not in Recent")
    }

    /// Below the threshold there is no Popular tab, and nothing is asked.
    @Test func belowTheThresholdNothingIsRanked() async {
        let provider = FewComments()
        let viewModel = PostDetailViewModel(postID: PostID("post-1"), repository: PopularFeedProvider(), commentsProvider: provider)
        var recent: [String] = []
        var popularEmitted = false
        viewModel.onCommentsChange = { if case .loaded(let models) = $0 { recent = models.map(\.id) } }
        viewModel.onPopularCommentsChange = { _ in popularEmitted = true }
        viewModel.viewDidLoad()
        #expect(await settle { recent.count == 2 })
        try? await Task.sleep(for: .milliseconds(100))
        #expect(!popularEmitted)
        #expect(await provider.rankedAsks == 0)
        withExtendedLifetime(viewModel) {}
    }

    @Test func aRepeatedRankingIsDropped() {
        let merged = RankedCommentsStream.appending([comment("b"), comment("c")], to: [comment("a"), comment("b")])
        #expect(merged.map(\.id) == ["a", "b", "c"])
    }
}
