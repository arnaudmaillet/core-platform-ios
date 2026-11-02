import CoreModels
import DesignSystem
import MediaCore
import Testing
import UIKit
@testable import Feed

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

private func comment(_ index: Int) -> CommentEntry {
    CommentEntry(
        id: "c\(index)", authorID: ProfileID("other"), authorName: "Ava Moreau", authorHandle: "ava",
        body: index % 3 == 0 ? "Comment \(index), long enough to take a second line in the row at this width"
            : "Comment \(index)",
        createdAt: Date(timeIntervalSinceNow: -Double(index) * 60)
    )
}

/// `count` comments newest first, in pages of `pageSize`, Recent's and
/// Popular's alike; the pages asked for are counted.
private actor TieredComments: CommentsProviding {
    let all: [CommentEntry]
    let pageSize: Int
    private(set) var rankedPagesAsked = 0

    init(count: Int, pageSize: Int) {
        all = (0..<count).map(comment)
        self.pageSize = pageSize
    }

    private func page(after token: String?) -> CommentPage {
        let start = token.flatMap(Int.init) ?? 0
        let end = min(all.count, start + pageSize)
        return CommentPage(entries: Array(all[start..<end]), nextPageToken: end < all.count ? "\(end)" : nil)
    }

    func loadComments(for postID: PostID) async throws -> [CommentEntry] { Array(all.prefix(pageSize)) }
    func loadCommentsPage(for postID: PostID, after pageToken: String?) async throws -> CommentPage {
        page(after: pageToken)
    }
    func loadCommentsPage(for postID: PostID, after pageToken: String?, order: CommentSortOrder) async throws -> CommentPage {
        if order == .popular { rankedPagesAsked += 1 }
        return page(after: pageToken)
    }
    func addComment(_ body: String, to postID: PostID, parentID: String?, commentID: String) async throws -> CommentEntry {
        comment(999)
    }
}

/// **Comments read in tiers (#2042).** The first tier is never taller than
/// the stream's room; each "More" adds about 1.5 to 2 rooms; the next tier is
/// loaded ahead; at the bottom edge of what is shown, an upward drag goes to
/// the next post.
@MainActor
struct CommentTiersTests {
    // MARK: - The arithmetic

    @Test func theFirstTierTakesTheThreadsThatFitOneRoom() {
        #expect(CommentTiers.firstTierCount(heights: [100, 200, 300, 400], viewport: 600) == 3)
        #expect(CommentTiers.firstTierCount(heights: [100, 200, 300], viewport: 600, lead: 150) == 2)
        #expect(CommentTiers.firstTierCount(heights: [700], viewport: 600) == 0, "a thread taller than the room fits nothing")
    }

    @Test func aLaterTierIsOneAndAHalfToTwoRooms() {
        // Stops once it reaches 1.5 rooms (900 of 600).
        #expect(CommentTiers.nextTierCount(heights: Array(repeating: 200, count: 10), viewport: 600) == 5)
        // Never past 2 rooms: a thread that would cross 1200 waits.
        #expect(CommentTiers.nextTierCount(heights: [800, 500, 100], viewport: 600) == 1)
        // Always one, however tall.
        #expect(CommentTiers.nextTierCount(heights: [2000], viewport: 600) == 1)
        #expect(CommentTiers.nextTierCount(heights: [], viewport: 600) == 0)
    }

    @Test func threadsKeepTheirRepliesAndFolds() {
        let items = ["A", "a1", "a2", "B", "C", "c1"]
        let threads = CommentTiers.threads(of: items) { $0.first?.isUppercase == true }
        #expect(threads == [["A", "a1", "a2"], ["B"], ["C", "c1"]])
        #expect(CommentTiers.threads(of: ["x1", "A"]) { $0.first?.isUppercase == true } == [["x1"], ["A"]])
    }

    /// The hand-off is decided as the drag begins: at the bottom edge, heading
    /// up more than sideways.
    @Test func onlyAnUpwardDragFromTheBottomEdgeGoesToTheNextPost() {
        let up = CGPoint(x: 0, y: -900)
        #expect(CommentStream.dragGoesToNextPost(atBottomEdge: true, velocity: up, translation: .zero))
        #expect(!CommentStream.dragGoesToNextPost(atBottomEdge: false, velocity: up, translation: .zero))
        #expect(!CommentStream.dragGoesToNextPost(atBottomEdge: true, velocity: CGPoint(x: 0, y: 900), translation: .zero))
        #expect(!CommentStream.dragGoesToNextPost(atBottomEdge: true, velocity: CGPoint(x: -900, y: -300), translation: .zero),
                "a sideways drag is the tabs'")
        #expect(CommentStream.dragGoesToNextPost(atBottomEdge: true, velocity: .zero, translation: CGPoint(x: 0, y: -12)))
    }

    // MARK: - On a panel

    private static let looks = 3_000

    private func settle(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<Self.looks where !condition() {
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    private func settle(_ condition: () async -> Bool) async -> Bool {
        for _ in 0..<Self.looks where !(await condition()) {
            try? await Task.sleep(for: .milliseconds(10))
        }
        return await condition()
    }

    /// A panel in a vertical feed (a page swipe handler: tiers on), in a
    /// window of `size` — the iPhone 18 Pro's by default.
    private func panel(
        _ provider: TieredComments, size: CGSize = CGSize(width: 402, height: 874), caption: String = "A text post"
    ) -> (PostDetailViewController, UIWindow) {
        let controller = PostDetailViewController(
            viewModel: PostDetailViewModel(postID: PostID("p"), repository: NoPostFeed(), commentsProvider: provider),
            imagePipeline: ImagePipeline(fetcher: PlaceholderImageFetcher())
        )
        let window = UIWindow(frame: CGRect(origin: .zero, size: size))
        window.rootViewController = controller
        window.isHidden = false
        controller.setEngagedInsets(top: 100, bottomInset: 34)
        controller.setEngagedPageSwipeHandler { _, _, _ in }
        controller.seedCaption(caption, timestamp: "2h", authorName: "Ava Moreau")
        return (controller, window)
    }

    /// Whether the button shows, the keyboard pinned down first: the bar
    /// follows the GLOBAL keyboard notifications, which suites running beside
    /// this one in the test host post.
    private static func showsMore(_ stream: CommentStream, _ controller: PostDetailViewController) -> Bool {
        controller.composeBar.setKeyboardOpen(false)
        return stream.showsMoreButton
    }

    /// Loaded, and laid out in its page: a stream with its comments may not
    /// have its frame yet.
    private static func laidOut(_ stream: CommentStream) -> Bool {
        stream.collectionView.layoutIfNeeded()
        return stream.commentsLoaded && stream.collectionView.bounds.height > 0
            && stream.collectionView.contentSize.height > 0
    }

    private static func geometry(_ stream: CommentStream) -> String {
        let view = stream.collectionView
        return "offset \(view.contentOffset.y) insets \(view.adjustedContentInset.top)/\(view.adjustedContentInset.bottom) "
            + "content \(view.contentSize.height) bounds \(view.bounds.height) shown \(stream.revealedThreadCount) "
            + "hidden \(stream.hiddenThreadCount) next \(stream.hasNextTier)"
    }

    /// The stream's room between the bar and the composer.
    private static func room(_ stream: CommentStream) -> CGFloat { stream.debugTierRoom }

    /// The content height of the comment rows shown (the caption and the end
    /// room included).
    private static func content(_ stream: CommentStream) -> CGFloat {
        stream.collectionView.layoutIfNeeded()
        return stream.collectionView.contentSize.height
    }

    /// ⚠️ TIER 0 FITS ONE ROOM, on the iPhone 18 Pro and on the iPhone SE
    /// (the owner, 2026-11-02): measured against the device's own room, never
    /// a constant.
    @Test(arguments: [CGSize(width: 402, height: 874), CGSize(width: 375, height: 667)])
    func theFirstTierFitsTheRoom(_ size: CGSize) async {
        let (controller, window) = panel(TieredComments(count: 40, pageSize: 40), size: size)
        defer { window.isHidden = true }
        let stream = controller.popular
        #expect(await settle { Self.laidOut(stream) && stream.revealedThreadCount > 0 })
        #expect(stream.hiddenThreadCount > 0, "the premise: more than one tier")
        let content = Self.content(stream)
        #expect(content <= Self.room(stream) + 1, "\(size): tier 0 is \(content) in a room of \(Self.room(stream))")
        #expect(Self.showsMore(stream, controller), "at tier 0's end the button shows: \(Self.geometry(stream))")
    }

    /// "More" adds a tier of 1.5 to 2 rooms (give or take a thread), and the
    /// stream scrolls into it.
    @Test func moreAddsATierOfOneAndAHalfToTwoRooms() async {
        let (controller, window) = panel(TieredComments(count: 60, pageSize: 60))
        defer { window.isHidden = true }
        let stream = controller.popular
        #expect(await settle { Self.laidOut(stream) && stream.hiddenThreadCount > 0 })
        let before = Self.content(stream)
        let room = Self.room(stream)

        stream.revealNextTier(animated: false)
        let added = Self.content(stream) - before
        #expect(added >= room * 1.3 && added <= room * 2.1, "the tier added \(added) to a room of \(room): \(Self.geometry(stream))")
        #expect(stream.collectionView.contentOffset.y > -stream.collectionView.contentInset.top,
                "the stream did not scroll into the new tier")
    }

    /// The next tier is loaded ahead: with less held than a tier past what is
    /// shown, Popular's next ranked page is asked for.
    @Test func theNextTierIsLoadedAhead() async {
        let provider = TieredComments(count: 60, pageSize: 12)
        let (controller, window) = panel(provider)
        defer { window.isHidden = true }
        #expect(await settle { Self.laidOut(controller.popular) })
        #expect(await settle { await provider.rankedPagesAsked >= 2 }, "Popular's next page was not asked ahead")
    }

    /// Recent mirrored: tier 0 is its newest, the button stands at its top.
    @Test func recentsFirstTierIsItsNewestAndItsButtonIsAtTheTop() async {
        let (controller, window) = panel(TieredComments(count: 40, pageSize: 40))
        defer { window.isHidden = true }
        let stream = controller.recent
        #expect(await settle { Self.laidOut(stream) && stream.hiddenThreadCount > 0 })
        controller.showStream(.recent, animated: false)
        #expect(Self.content(stream) <= Self.room(stream) + 1)
        let bodies = stream.collectionView.indexPathsForVisibleItems.sorted().compactMap {
            stream.collectionView.cellForItem(at: $0).flatMap(PostDetailViewController.commentRow(in:))?.bodyTextLabel.text
        }
        #expect(bodies.last == "Comment 0, long enough to take a second line in the row at this width",
                "Recent's newest is not at its end: \(bodies)")
        let shows = await settle { Self.showsMore(stream, controller) }
        #expect(shows, "no More at Recent's top (offset \(stream.collectionView.contentOffset.y), inset \(stream.collectionView.adjustedContentInset.top), content \(Self.content(stream)), room \(Self.room(stream)), slack \(stream.bottomAnchorSlack))")
        #expect(stream.debugMoreButton.frame.minY < stream.collectionView.bounds.midY, "the button is not at the top")
    }

    /// Off the vertical feed (no page swipe: the published text post's sheet),
    /// nothing is cut.
    @Test func withoutAFeedAroundNothingIsCut() async {
        let provider = TieredComments(count: 40, pageSize: 40)
        let controller = PostDetailViewController(
            viewModel: PostDetailViewModel(postID: PostID("p"), repository: NoPostFeed(), commentsProvider: provider),
            imagePipeline: ImagePipeline(fetcher: PlaceholderImageFetcher())
        )
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        window.rootViewController = controller
        window.isHidden = false
        defer { window.isHidden = true }
        #expect(await settle { Self.laidOut(controller.recent) })
        #expect(controller.recent.hiddenThreadCount == 0)
        #expect(!Self.showsMore(controller.recent, controller))
    }

    // MARK: - The caption

    private static let longCaption = Array(
        repeating: "A caption that goes on and on about the light over the harbour at dawn.", count: 40
    ).joined(separator: " ")

    private static func labels(in view: UIView) -> [UILabel] {
        view.subviews.flatMap { ($0 as? UILabel).map { [$0] } ?? [] + labels(in: $0) }
    }

    private static func captionCell(_ stream: CommentStream) -> UICollectionViewCell? {
        stream.collectionView.layoutIfNeeded()
        return stream.collectionView.visibleCells.first { $0 is CaptionBubbleCell }
    }

    /// ⚠️ A CAPTION IS NEVER CUT ON THESE SCREENS (the owner, 2026-11-02):
    /// taller than the room, it is tier 0 whole — no "… more" — and "More
    /// comments" stands right after it. On the iPhone 18 Pro and the SE.
    @Test(arguments: [CGSize(width: 402, height: 874), CGSize(width: 375, height: 667)])
    func aLongCaptionIsWholeAndMoreFollowsIt(_ size: CGSize) async {
        let (controller, window) = panel(TieredComments(count: 20, pageSize: 20), size: size, caption: Self.longCaption)
        defer { window.isHidden = true }
        let stream = controller.popular
        #expect(await settle { Self.laidOut(stream) && Self.captionCell(stream) != nil })
        #expect(Self.captionCell(stream).map { Self.labels(in: $0).contains { $0.text == Self.longCaption } } == true,
                "\(size): the caption is not whole")
        #expect(stream.revealedThreadCount == 0, "\(size): no thread fits beside a caption taller than the room")
        #expect(stream.hiddenThreadCount == 20)
        #expect(!Self.showsMore(stream, controller), "\(size): the button shows before the caption's end")
        // At the caption's end, the button.
        let view = stream.collectionView
        view.contentOffset.y = view.contentSize.height + view.adjustedContentInset.bottom - view.bounds.height
        #expect(Self.showsMore(stream, controller), "\(size): no More after the caption: \(Self.geometry(stream))")
    }

    // MARK: - The rows' height

    /// ⚠️ A REUSED ROW MEASURES ITS BODY AT ITS REAL WIDTH: laid out wide
    /// once, then asked again at the row's width, a two-line comment is two
    /// lines tall — it kept a one-line height, its end under an ellipsis.
    @Test func aReusedRowMeasuresItsBodyAtItsWidth() {
        let cell = ThreadRowCell(frame: CGRect(x: 0, y: 0, width: 900, height: 80))
        let model = CommentDisplayModel(entry: CommentEntry(
            id: "x", authorID: ProfileID("p"), authorName: "Zed Aldrin", authorHandle: "zed",
            body: "The pacing on that last cut is genuinely perfect.", createdAt: Date()
        ))
        cell.row.configure(with: model)
        cell.contentView.layoutIfNeeded()
        let attributes = UICollectionViewLayoutAttributes(forCellWith: IndexPath(item: 0, section: 0))
        attributes.frame = CGRect(x: 0, y: 0, width: 370, height: 44)
        let fitted = cell.preferredLayoutAttributesFitting(attributes).frame.height
        let oneLine = UIFont.appFont(forTextStyle: .body).lineHeight
        #expect(cell.row.bodyTextLabel.bounds.height > oneLine * 1.5 || fitted > 70,
                "the two-line body measured \(fitted) (label \(cell.row.bodyTextLabel.bounds.height))")
    }
}
