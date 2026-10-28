import CoreModels
import DesignSystem
import MediaCore
import Testing
import UIKit
@testable import Feed

/// THE COMMENT STREAM WITHOUT THE TEXT PAGE'S CHROME (`threadChrome: false`) —
/// a media post's panel and the pushed comments screen: one section whatever
/// the comments' days, a menu carried by each ROW and none by the stream, and
/// the footer capping the view with the stream inset under it.
///
/// Pinned when the text page gained day sections and a lifted menu, because
/// nothing else in the suite looked at the stream's sections, its rows' menus
/// or its engaged footer — a change leaking past the parameter would have
/// passed everything. `UnifiedThreadChromeTests` is the other side.
@MainActor
struct PostDetailStreamShapeTests {
    /// The post never arrives: these tests are about the stream, which the
    /// seeded caption leads without it.
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

    private final class Prefetched: CommentsProviding, @unchecked Sendable {
        let entries: [CommentEntry]
        init(_ entries: [CommentEntry]) { self.entries = entries }
        nonisolated func cachedTopComments(for postID: PostID) -> [CommentEntry]? { entries }
        func loadComments(for postID: PostID) async throws -> [CommentEntry] { entries }
        func addComment(
            _ body: String, to postID: PostID, parentID: String?, commentID: String
        ) async throws -> CommentEntry {
            throw CommentsError.transport(message: "not used")
        }
    }

    private static func entry(_ id: String, ageInDays: Double) -> CommentEntry {
        CommentEntry(
            id: id, authorID: ProfileID("prof-1"), authorName: "Ava Moreau", authorHandle: "ava",
            body: "Comment \(id)", createdAt: Date().addingTimeInterval(-ageInDays * 86_400)
        )
    }

    /// Comments from today, the day before and three days back: exactly the
    /// spread the flag-on stream splits into three day sections.
    private static let spreadAcrossDays = [
        entry("c1", ageInDays: 0), entry("c2", ageInDays: 1.2), entry("c3", ageInDays: 3),
    ]

    /// The resting text page's construction, in a window so rows realize.
    private func makeStream(
        _ entries: [CommentEntry]
    ) async throws -> (PostDetailViewController, UICollectionView, UIWindow) {
        let controller = PostDetailViewController(
            viewModel: PostDetailViewModel(
                postID: PostID("p"),
                repository: NoPostFeed(),
                commentsProvider: Prefetched(entries)
            ),
            imagePipeline: ImagePipeline(fetcher: PlaceholderImageFetcher())
        )
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = controller
        window.isHidden = false
        controller.seedCaption("A text post", timestamp: "2h", authorName: "Ava Moreau")
        let stream = try #require(Self.firstView(UICollectionView.self, in: controller.view))
        // Comments land through a task; wait for the rows, not for a clock.
        let expected = 1 + entries.count
        var attempts = 0
        while stream.numberOfItems(inSection: 0) != expected, attempts < 500 {
            attempts += 1
            try await Task.sleep(for: .milliseconds(10))
        }
        stream.layoutIfNeeded()
        return (controller, stream, window)
    }

    /// A comment's Copy says so (#803), over the composer.
    @Test func copyingACommentShowsACopiedToast() async throws {
        let (controller, _, window) = try await makeStream(Self.spreadAcrossDays)
        defer { window.isHidden = true }
        #expect(Self.firstView(ToastView.self, in: controller.view) == nil)
        controller.confirmCopied()
        #expect(Self.firstView(ToastView.self, in: controller.view)?.style == .confirmation, "the copy said nothing")
    }

    private static func firstView<T: UIView>(_ type: T.Type, in view: UIView) -> T? {
        if let match = view as? T { return match }
        for subview in view.subviews {
            if let match = firstView(type, in: subview) { return match }
        }
        return nil
    }

    /// The post's send arrow is the conversation's blue — ONE tint for every
    /// composer (`CommentsInputBar.sendTint`; the thread's twin is
    /// `ConversationThreadViewControllerTests.theSendArrowIsThePostsBlue`).
    @Test func theSendArrowIsTheComposersOneBlue() async throws {
        let (controller, _, _) = try await makeStream(Self.spreadAcrossDays)
        let bar = try #require(Self.firstView(CommentsInputBar.self, in: controller.view))
        bar.draftText = "Nice one"
        let color = bar.debugFieldActionButton.configuration?.baseForegroundColor
        for style in [UIUserInterfaceStyle.light, .dark] {
            let traits = UITraitCollection(userInterfaceStyle: style)
            #expect(color?.resolvedColor(with: traits) == CommentsInputBar.sendTint.resolvedColor(with: traits))
        }
    }

    @Test func commentsFromSeveralDaysShareTheOneSection() async throws {
        let (_, stream, _) = try await makeStream(Self.spreadAcrossDays)
        #expect(stream.numberOfSections == 1)
        #expect(stream.numberOfItems(inSection: 0) == 4, "the caption, then the three comments")
    }

    @Test func eachCommentRowCarriesItsOwnMenuAndTheStreamCarriesNone() async throws {
        let (_, stream, _) = try await makeStream(Self.spreadAcrossDays)
        let cell = try #require(stream.cellForItem(at: IndexPath(item: 1, section: 0)) as? CommentCell)
        #expect(cell.row.interactions.contains { $0 is UIContextMenuInteraction })
        #expect(!stream.interactions.contains { $0 is UIContextMenuInteraction })
    }

    @Test func theEngagedFooterCapsTheViewAndInsetsTheStream() async throws {
        let (controller, stream, _) = try await makeStream(Self.spreadAcrossDays)
        controller.setEngagedInsets(top: 120, bottomInset: 34)
        // Within half a point: fractional-scale CGFloats do not compare
        // exactly (the value read back printed as 96.0 and still failed `==`).
        #expect(abs(stream.contentInset.top - 120) < 0.5)
        // The bar's rest gap above the footer line, the resting bar (its
        // two-bubble column over the input row), and the 16pt breath above it.
        let clearance = SnapActionColumn.inputRestingGap + SnapActionColumn.bottomBreath
            + CommentsInputBar.restingHeight(for: .large) + 16
        #expect(abs(stream.contentInset.bottom - (34 + clearance)) < 0.5)
        let topTwo = controller.view.subviews.suffix(2)
        #expect(topTwo.first is ProgressiveFrostView, "the footer's frost sits under the composer")
        #expect(topTwo.last is CommentsInputBar, "the composer caps the view")
    }

    // MARK: - #1799: a short stream starts from the bottom

    /// The stream engaged and laid out at its settled size.
    private func engage(_ controller: PostDetailViewController, _ stream: UICollectionView, anchored: Bool) {
        controller.anchorsShortStream = anchored
        controller.setEngagedInsets(top: 120, bottomInset: 34)
        controller.view.layoutIfNeeded()
        stream.layoutIfNeeded()
    }

    /// Where the content ends on screen, and where the stream's room ends.
    private static func contentBottomAndRoomBottom(_ stream: UICollectionView) -> (content: CGFloat, room: CGFloat) {
        (stream.contentSize.height - stream.contentOffset.y, stream.bounds.height - stream.contentInset.bottom)
    }

    /// The experiment on: the caption and three comments are one block,
    /// resting just above the composer, the slack worn on top of the engaged
    /// top, and the stream resting at `-(top + slack)`.
    @Test func aShortStreamRestsAboveTheComposerOnTopOfTheEngagedTop() async throws {
        let (controller, stream, window) = try await makeStream(Self.spreadAcrossDays)
        defer { window.isHidden = true }
        engage(controller, stream, anchored: true)

        let slack = controller.bottomAnchorSlack
        #expect(slack > 100, "a three-comment stream wears no slack: \(slack)")
        #expect(abs(stream.contentInset.top - (120 + slack)) < 0.5)
        #expect(abs(stream.contentOffset.y + 120 + slack) < 0.5, "the stream does not rest at its top")
        #expect(controller.streamIsAtTop, "the pull-down dismissal would not arm")
        let edges = Self.contentBottomAndRoomBottom(stream)
        #expect(abs(edges.content - edges.room) < 1, "the block ends at \(edges.content), the room at \(edges.room)")
    }

    /// The experiment off: the engaged top alone, as before.
    @Test func withoutTheExperimentTheStreamHangsFromTheEngagedTop() async throws {
        let (controller, stream, window) = try await makeStream(Self.spreadAcrossDays)
        defer { window.isHidden = true }
        engage(controller, stream, anchored: false)
        #expect(controller.bottomAnchorSlack == 0)
        #expect(abs(stream.contentInset.top - 120) < 0.5)
    }

    /// A stream taller than its room wears no slack.
    @Test func aLongStreamWearsNoSlack() async throws {
        let many = (0..<30).map { Self.entry("c\($0)", ageInDays: 0) }
        let (controller, stream, window) = try await makeStream(many)
        defer { window.isHidden = true }
        engage(controller, stream, anchored: true)
        #expect(controller.bottomAnchorSlack == 0)
        #expect(abs(stream.contentInset.top - 120) < 0.5)
    }

    /// No comments: the empty page is its block alone, so the caption and the
    /// invitation rest together above the composer rather than a page
    /// filling the room.
    @Test func withNoCommentsTheCaptionRestsAboveTheComposer() async throws {
        let controller = PostDetailViewController(
            viewModel: PostDetailViewModel(
                postID: PostID("p"), repository: NoPostFeed(), commentsProvider: Prefetched([])
            ),
            imagePipeline: ImagePipeline(fetcher: PlaceholderImageFetcher())
        )
        controller.anchorsShortStream = true
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = controller
        window.isHidden = false
        defer { window.isHidden = true }
        controller.seedCaption("A text post", timestamp: "2h", authorName: "Ava Moreau")
        let stream = try #require(Self.firstView(UICollectionView.self, in: controller.view))
        engage(controller, stream, anchored: true)
        for _ in 0..<300 where controller.bottomAnchorSlack == 0 {
            try await Task.sleep(for: .milliseconds(10))
            stream.layoutIfNeeded()
        }
        #expect(controller.bottomAnchorSlack > 100, "the empty page still fills the room")
        let edges = Self.contentBottomAndRoomBottom(stream)
        #expect(abs(edges.content - edges.room) < 1)
    }
}
