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
        // The engaged top alone: the bottom anchor's slack is its own test.
        controller.anchorsShortStream = false
        controller.setEngagedInsets(top: 120, bottomInset: 34)
        // Within half a point: fractional-scale CGFloats do not compare
        // exactly (the value read back printed as 96.0 and still failed `==`).
        #expect(abs(stream.contentInset.top - 120) < 0.5)
        // The bar's rest gap above the footer line, the resting bar (its
        // two-bubble column over the input row), and a conversation's 8pt
        // breath above it, less the section's own 16pt bottom (#1923).
        let clearance = SnapActionColumn.inputRestingGap + SnapActionColumn.bottomBreath
            + CommentsInputBar.restingHeight(for: .large) + Spacing.sm - Spacing.lg
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

    /// The keyboard lifts the input row, and a short stream rises with it:
    /// the slack gives up what the keys take, so the block stays on the row
    /// rather than going behind the keyboard (#1799, the default since #1923).
    @Test func aShortStreamRisesWithTheKeyboard() async throws {
        let (controller, stream, window) = try await makeStream(Self.spreadAcrossDays)
        defer { window.isHidden = true }
        engage(controller, stream, anchored: true)
        let resting = controller.bottomAnchorSlack
        #expect(resting > 100)

        let covered: CGFloat = 300
        let screen = window.screen.bounds
        NotificationCenter.default.post(
            name: UIResponder.keyboardWillShowNotification,
            object: nil,
            userInfo: [
                UIResponder.keyboardFrameEndUserInfoKey:
                    NSValue(cgRect: CGRect(x: 0, y: screen.maxY - covered, width: screen.width, height: covered)),
            ]
        )
        controller.view.layoutIfNeeded()
        #expect(controller.bottomAnchorSlack < resting - 100, "the stream stayed down: \(resting) → \(controller.bottomAnchorSlack)")
        #expect(abs(stream.contentInset.top - (120 + controller.bottomAnchorSlack)) < 0.5)

        NotificationCenter.default.post(name: UIResponder.keyboardWillHideNotification, object: nil)
        controller.view.layoutIfNeeded()
        #expect(abs(controller.bottomAnchorSlack - resting) < 1, "the stream did not settle back")
    }

    /// A tap in the empty room above a short stream closes the comments
    /// (#1926); a tap on the caption does not, and a stream that fills its
    /// room has no such room.
    @Test func aTapInTheEmptyRoomAboveAShortStreamCloses() async throws {
        let (controller, stream, window) = try await makeStream(Self.spreadAcrossDays)
        defer { window.isHidden = true }
        engage(controller, stream, anchored: true)
        try #require(controller.bottomAnchorSlack > 100)
        var closes = 0
        controller.setEmptyRoomTapHandler { closes += 1 }

        // The caption is the content's first row, at the top of the content.
        let caption = try #require(stream.cellForItem(at: IndexPath(item: 0, section: 0)))
        controller.debugTapStream(at: CGPoint(x: caption.frame.midX, y: caption.frame.midY))
        #expect(closes == 0, "a tap on the caption closed the comments")

        // Above it: the room the anchor leaves, on screen under the top bar.
        let room = CGPoint(x: stream.bounds.midX, y: -controller.bottomAnchorSlack / 2)
        #expect(stream.convert(room, to: controller.view).y > 120, "the point is not below the engaged top")
        controller.debugTapStream(at: room)
        #expect(closes == 1, "a tap in the empty room did not close the comments")

        // Unwired (a text page), nothing.
        controller.setEmptyRoomTapHandler(nil)
        controller.debugTapStream(at: room)
        #expect(closes == 1)
    }

    @Test func aStreamThatFillsItsRoomHasNoEmptyRoomToTap() async throws {
        let many = (0..<30).map { Self.entry("c\($0)", ageInDays: 0) }
        let (controller, stream, window) = try await makeStream(many)
        defer { window.isHidden = true }
        engage(controller, stream, anchored: true)
        var closes = 0
        controller.setEmptyRoomTapHandler { closes += 1 }
        controller.debugTapStream(at: CGPoint(x: stream.bounds.midX, y: -10))
        #expect(closes == 0, "a full stream closed on a tap under the bar")
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
