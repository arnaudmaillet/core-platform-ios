import CoreModels
import DesignSystem
import MediaCore
import MediaCoreFixtures
import Testing
import UIKit
@testable import Feed
@testable import ThreadKit

/// NO "NO COMMENTS YET" PAGE IN THE COMMENTS (#2477, the owner 2026-11-17): a
/// post with no comments opens on an empty list above the composer, on
/// Popular and on Recent — a text post's caption row alone, a media post's
/// nothing at all. The empty page's row stays for a failed first page, with
/// its Try Again (#798); the slow page (#1770, `SectionsByPresenceTests`) and
/// the draft (`TextPostComposePageTests`) keep theirs too.
@MainActor
struct CommentsEmptyPostTests {
    /// The post never arrives: the stream is led by the seeded caption.
    private final class NoPostFeed: FeedProviding, @unchecked Sendable {
        func cachedFirstPage() async -> [FeedEntry]? { nil }
        func loadFirstPage() async throws -> FeedPage { FeedPage(entries: [], nextPageToken: nil, isCold: false) }
        func loadPage(afterToken token: String) async throws -> FeedPage {
            FeedPage(entries: [], nextPageToken: nil, isCold: false)
        }
        func loadPost(_ id: PostID) async throws -> FeedEntry {
            try await Task.sleep(for: .seconds(3600))
            throw CancellationError()
        }
    }

    /// No comments, or a first page that fails.
    private final class NoComments: CommentsProviding, @unchecked Sendable {
        let fails: Bool
        init(fails: Bool) { self.fails = fails }
        func loadComments(for postID: PostID) async throws -> [CommentEntry] {
            if fails { throw CommentsError.transport(message: "down") }
            return []
        }
        func addComment(
            _ body: String, to postID: PostID, parentID: String?, commentID: String
        ) async throws -> CommentEntry {
            throw CommentsError.transport(message: "not used")
        }
    }

    private func panel(
        _ kind: CommentStream.Kind, caption: Bool, failing: Bool = false
    ) async throws -> (PostDetailViewController, CommentStream, UIWindow) {
        let controller = PostDetailViewController(
            viewModel: PostDetailViewModel(
                postID: PostID("p"), repository: NoPostFeed(), commentsProvider: NoComments(fails: failing)
            ),
            imagePipeline: ImagePipeline(fetcher: PlaceholderImageFetcher())
        )
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = controller
        window.isHidden = false
        if caption { controller.seedCaption("A text post", timestamp: "2h", authorName: "Ava Moreau") }
        controller.loadViewIfNeeded()
        controller.showStream(kind, animated: false)
        let stream = kind == .popular ? controller.popular : controller.recent
        // The first page lands through a task: wait on it, a look at a time.
        for _ in 0..<3_000 where !stream.commentsLoaded {
            try await Task.sleep(for: .milliseconds(10))
        }
        stream.collectionView.layoutIfNeeded()
        return (controller, stream, window)
    }

    private static func all<T: UIView>(_ type: T.Type, in view: UIView) -> [T] {
        ((view as? T).map { [$0] } ?? []) + view.subviews.flatMap { all(type, in: $0) }
    }

    /// The views of `type` in the rows on screen. A row that went (the
    /// taking-longer row a starved run shows before the page lands) can
    /// stay in the list's reuse pool as a hidden subview: it is not shown.
    private static func shown<T: UIView>(_ type: T.Type, in stream: CommentStream) -> [T] {
        stream.collectionView.layoutIfNeeded()
        return stream.collectionView.visibleCells.filter { !$0.isHidden }.flatMap { all(type, in: $0) }
    }

    /// A text post with no comments: the caption row alone, on either tab —
    /// no glyph, no "No comments yet", no "Be the first to comment."
    @Test(arguments: [CommentStream.Kind.popular, .recent])
    func aTextPostWithNoCommentsIsItsCaptionAlone(_ kind: CommentStream.Kind) async throws {
        let (_, stream, window) = try await panel(kind, caption: true)
        defer { window.isHidden = true }
        #expect(stream.commentsLoaded)
        #expect(stream.debugItems == [.caption], "the caption row, and nothing under it")
        #expect(Self.shown(CommentsEmptyPageCell.self, in: stream).isEmpty)
        #expect(Self.shown(EmptyStateView.self, in: stream).isEmpty)
        let words = Self.shown(UILabel.self, in: stream).compactMap(\.text)
        #expect(!words.contains("No comments yet"))
        #expect(!words.contains("Be the first to comment."))
    }

    /// A media post with no comments: nothing between the header and the
    /// composer, on either tab.
    @Test(arguments: [CommentStream.Kind.popular, .recent])
    func aMediaPostWithNoCommentsIsAnEmptyList(_ kind: CommentStream.Kind) async throws {
        let (_, stream, window) = try await panel(kind, caption: false)
        defer { window.isHidden = true }
        #expect(stream.commentsLoaded)
        #expect(stream.debugItems.isEmpty, "no empty page's row")
        #expect(Self.shown(CommentsEmptyPageCell.self, in: stream).isEmpty)
    }

    /// A first page that fails keeps its row: the reason, and Try Again.
    @Test func aFailedFirstPageKeepsItsRowAndTryAgain() async throws {
        let (_, stream, window) = try await panel(.recent, caption: false, failing: true)
        defer { window.isHidden = true }
        #expect(stream.commentsLoaded)
        #expect(stream.debugItems == [.emptyState])
        let row = try #require(Self.shown(CommentsEmptyPageCell.self, in: stream).first)
        let page = try #require(Self.all(EmptyStateView.self, in: row).first)
        #expect(page.debugTitle != nil, "the failure's reason")
        #expect(page.debugTitle != "No comments yet")
        #expect(Self.all(UIButton.self, in: row).contains { !$0.isHidden && $0.configuration?.title == "Try Again" })
    }
}
