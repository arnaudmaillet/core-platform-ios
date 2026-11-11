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
/// Popular's alike. The pages asked for are counted, and Recent's older
/// pages can be made to fail.
private actor PagedComments: CommentsProviding {
    let all: [CommentEntry]
    let pageSize: Int
    private(set) var rankedPagesAsked = 0
    private(set) var olderPagesAsked = 0
    private var failsOlderPages = false

    init(count: Int, pageSize: Int) {
        all = (0..<count).map(comment)
        self.pageSize = pageSize
    }

    func setFailsOlderPages(_ fails: Bool) { failsOlderPages = fails }

    private func page(after token: String?) -> CommentPage {
        let start = token.flatMap(Int.init) ?? 0
        let end = min(all.count, start + pageSize)
        return CommentPage(entries: Array(all[start..<end]), nextPageToken: end < all.count ? "\(end)" : nil)
    }

    func loadComments(for postID: PostID) async throws -> [CommentEntry] { Array(all.prefix(pageSize)) }
    func loadCommentsPage(for postID: PostID, after pageToken: String?) async throws -> CommentPage {
        if pageToken != nil {
            olderPagesAsked += 1
            if failsOlderPages { throw CommentsError.transport(message: "offline") }
        }
        return page(after: pageToken)
    }
    func loadCommentsPage(for postID: PostID, after pageToken: String?, order: CommentSortOrder) async throws -> CommentPage {
        guard order == .popular else { return try await loadCommentsPage(for: postID, after: pageToken) }
        rankedPagesAsked += 1
        return page(after: pageToken)
    }
    func addComment(_ body: String, to postID: PostID, parentID: String?, commentID: String) async throws -> CommentEntry {
        comment(999)
    }
}

/// **The comments panel read in its room (#2298).** Popular shows the caption
/// and the whole threads that fit between the bar and the composer, then "See
/// all n comments", which turns to Recent; it is never paged. Recent loads
/// its older pages only on its "Earlier comments" row, without moving the
/// list. The tiers (#2042) are gone; the edge hand-off stays until the pull
/// replaces it.
@MainActor
@Suite(.serialized)
struct CommentPanelRoomTests {
    // MARK: - The cut, pure

    /// Everything fits and the server holds no more: every thread, no "See
    /// all", nothing to scroll.
    @Test func whatFitsWholeShowsWholeWithoutSeeAll() {
        let cut = PopularCommentsCut(
            threadHeights: [100, 100, 100, 100], room: 500, lead: 80, seeAllHeight: 40, sourceHasMore: false
        )
        #expect(cut == PopularCommentsCut(threadHeights: [100, 100, 100, 100], room: 500, lead: 80, seeAllHeight: 40, sourceHasMore: false))
        #expect(cut.shownThreads == 4)
        #expect(!cut.showsSeeAll)
    }

    /// More than fits: the whole threads that fit beside "See all", which
    /// stands last — never a thread cut in half.
    @Test func moreThanFitsKeepsRoomForSeeAll() {
        let cut = PopularCommentsCut(
            threadHeights: [100, 100, 100, 100, 100], room: 500, lead: 80, seeAllHeight: 40, sourceHasMore: false
        )
        // 80 + 40 + 3 × 100 = 420; a fourth would reach 520.
        #expect(cut.shownThreads == 3)
        #expect(cut.showsSeeAll)
        // A tall thread stops the cut: the ones after it wait behind "See all".
        let tall = PopularCommentsCut(
            threadHeights: [100, 400, 50], room: 500, lead: 80, seeAllHeight: 40, sourceHasMore: false
        )
        #expect(tall.shownThreads == 1)
        #expect(tall.showsSeeAll)
    }

    /// A server with another ranked page: "See all" even when what is held
    /// fits.
    @Test func moreOnTheServerEndsOnSeeAll() {
        let cut = PopularCommentsCut(threadHeights: [100, 100], room: 500, lead: 80, seeAllHeight: 40, sourceHasMore: true)
        #expect(cut.shownThreads == 2)
        #expect(cut.showsSeeAll)
    }

    /// ⚠️ NEVER ZERO: a caption taller than the room still has its first
    /// thread under it — the one case where the page scrolls (the caption is
    /// never truncated) — then "See all" when there is more.
    @Test func aCaptionTallerThanTheRoomStillShowsTheFirstThread() {
        let more = PopularCommentsCut(threadHeights: [100, 100, 100], room: 500, lead: 900, seeAllHeight: 40, sourceHasMore: false)
        #expect(more.shownThreads == 1)
        #expect(more.showsSeeAll)
        let alone = PopularCommentsCut(threadHeights: [700], room: 500, lead: 80, seeAllHeight: 40, sourceHasMore: false)
        #expect(alone.shownThreads == 1, "a thread taller than the room shows, whole")
        #expect(!alone.showsSeeAll, "nothing more to see")
        let none = PopularCommentsCut(threadHeights: [], room: 500, lead: 80, seeAllHeight: 40, sourceHasMore: true)
        #expect(none.shownThreads == 0 && !none.showsSeeAll)
    }

    /// The room is the device's and the text size's: an SE's holds fewer
    /// threads than a Pro Max's, and a larger text size (taller rows, a
    /// taller caption, a taller "See all") fewer again.
    @Test(arguments: [(room: CGFloat(520), scale: CGFloat(1)), (room: 740, scale: 1), (room: 520, scale: 1.35), (room: 740, scale: 1.35)])
    func theCutIsMeasuredPerRoomAndTextSize(_ terms: (room: CGFloat, scale: CGFloat)) {
        let heights: [CGFloat] = [64, 88, 64, 112, 64, 88, 64, 64, 88, 64, 112, 64, 64, 88].map { $0 * terms.scale }
        let lead = 72 * terms.scale, seeAll = 36 * terms.scale
        let cut = PopularCommentsCut(threadHeights: heights, room: terms.room, lead: lead, seeAllHeight: seeAll, sourceHasMore: false)
        let shown = lead + heights.prefix(cut.shownThreads).reduce(0, +) + (cut.showsSeeAll ? seeAll : 0)
        #expect(shown <= terms.room + PopularCommentsCut.tolerance, "\(terms): \(shown) in a room of \(terms.room)")
        #expect(cut.showsSeeAll && cut.shownThreads < heights.count)
        let next = heights[cut.shownThreads]
        #expect(shown + next > terms.room, "\(terms): the next thread (\(next)) would have fit")
    }

    @Test func theFewerTheRoomTheFewerTheThreads() {
        let heights: [CGFloat] = Array(repeating: 80, count: 20)
        func shown(_ room: CGFloat, _ scale: CGFloat) -> Int {
            PopularCommentsCut(
                threadHeights: heights.map { $0 * scale }, room: room, lead: 72 * scale, seeAllHeight: 36 * scale,
                sourceHasMore: false
            ).shownThreads
        }
        #expect(shown(520, 1) < shown(740, 1), "an SE's room holds fewer than a Pro Max's")
        #expect(shown(740, 1.35) < shown(740, 1), "a larger text size holds fewer")
    }

    /// Threads: a top-level comment starts one; its replies and folds follow.
    @Test func threadsStartAtEachTopLevelComment() {
        let items = ["A", "a1", "a2", "B", "C", "c1"]
        let threads = PopularCommentsCut.threads(of: items) { $0.first?.isUppercase == true }
        #expect(threads == [["A", "a1", "a2"], ["B"], ["C", "c1"]])
        #expect(PopularCommentsCut.threads(of: ["x1", "A"]) { $0.first?.isUppercase == true } == [["x1"], ["A"]])
    }

    // MARK: - The edge hand-off (#2042, #2058), until the pull replaces it

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

    /// The mirror (#2058): at the top edge, heading down more than sideways.
    @Test func onlyADownwardDragFromTheTopEdgeGoesToThePreviousPost() {
        let down = CGPoint(x: 0, y: 900)
        #expect(CommentStream.dragGoesToPreviousPost(atTopEdge: true, velocity: down, translation: .zero))
        #expect(!CommentStream.dragGoesToPreviousPost(atTopEdge: false, velocity: down, translation: .zero))
        #expect(!CommentStream.dragGoesToPreviousPost(atTopEdge: true, velocity: CGPoint(x: 0, y: -900), translation: .zero))
        #expect(!CommentStream.dragGoesToPreviousPost(atTopEdge: true, velocity: CGPoint(x: 900, y: 300), translation: .zero),
                "a sideways drag is the tabs'")
        #expect(CommentStream.dragGoesToPreviousPost(atTopEdge: true, velocity: .zero, translation: CGPoint(x: 0, y: 12)))
    }

    /// ⚠️ THE TOP EDGE PAGES BACK ON A LATER POST ONLY (#2058): on the first
    /// the feed has no previous post to give, and the drag stays the stream's
    /// — the close (the text page's dismissal, the media layout's pull-down).
    @Test func theTopEdgePagesBackOnlyWhenTheFeedHasAPreviousPost() {
        let down = CGPoint(x: 0, y: 900)
        func handOff(top: Bool = true, bottom: Bool = false, _ velocity: CGPoint, pagesBack: Bool) -> CommentStream.EdgeHandOff? {
            CommentStream.edgeHandOff(
                atTopEdge: top, atBottomEdge: bottom, velocity: velocity, translation: .zero, pagesBack: pagesBack
            )
        }
        #expect(handOff(down, pagesBack: true) == .previousPost)
        #expect(handOff(down, pagesBack: false) == nil, "the first post keeps its close")
        #expect(handOff(top: false, down, pagesBack: true) == nil, "mid-stream, the drag scrolls")
        // A stream shorter than its room — a Popular that fits — is at both
        // edges: each way goes on.
        #expect(handOff(bottom: true, CGPoint(x: 0, y: -900), pagesBack: true) == .nextPost)
        #expect(handOff(bottom: true, down, pagesBack: true) == .previousPost)
    }

    /// The feed is asked only for a drag that goes back: the router's answer
    /// costs nothing on every other drag.
    @Test func theFeedIsAskedOnlyForADragThatGoesBack() {
        var asked = 0
        func pagesBack() -> Bool { asked += 1; return true }
        _ = CommentStream.edgeHandOff(
            atTopEdge: true, atBottomEdge: true, velocity: CGPoint(x: 0, y: -900), translation: .zero, pagesBack: pagesBack()
        )
        _ = CommentStream.edgeHandOff(
            atTopEdge: false, atBottomEdge: false, velocity: CGPoint(x: 0, y: 900), translation: .zero, pagesBack: pagesBack()
        )
        #expect(asked == 0)
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

    nonisolated private static let proMax = CGSize(width: 440, height: 956)
    nonisolated private static let pro = CGSize(width: 402, height: 874)
    nonisolated private static let se = CGSize(width: 375, height: 667)

    /// A text page in a vertical feed (a page swipe handler: the room's
    /// rules on), in a window of `size`.
    private func panel(
        _ provider: PagedComments, size: CGSize = Self.pro, caption: String = "A text post", inFeed: Bool = true
    ) -> (PostDetailViewController, UIWindow) {
        let controller = PostDetailViewController(
            viewModel: PostDetailViewModel(postID: PostID("p"), repository: NoPostFeed(), commentsProvider: provider),
            imagePipeline: ImagePipeline(fetcher: PlaceholderImageFetcher())
        )
        let window = UIWindow(frame: CGRect(origin: .zero, size: size))
        window.rootViewController = controller
        window.isHidden = false
        controller.setEngagedInsets(top: 100, bottomInset: 34)
        if inFeed { controller.setEngagedPageSwipeHandler({ _, _, _ in }, pagesBack: { false }) }
        controller.seedCaption(caption, timestamp: "2h", authorName: "Ava Moreau")
        return (controller, window)
    }

    /// Loaded, and laid out in its page.
    private static func laidOut(_ stream: CommentStream) -> Bool {
        stream.collectionView.layoutIfNeeded()
        return stream.commentsLoaded && stream.collectionView.bounds.height > 0
            && stream.collectionView.contentSize.height > 0
    }

    private static func topLevelCount(_ items: [StreamItem]) -> Int {
        items.filter { if case .comment = $0 { true } else { false } }.count
    }

    /// The rows' height as laid out: the content less its section's insets.
    private static func rowsHeight(_ stream: CommentStream, _ controller: PostDetailViewController) -> CGFloat {
        stream.collectionView.layoutIfNeeded()
        return stream.collectionView.contentSize.height - controller.streamSectionVerticalInsets
    }

    /// The cell showing `item`, laid out.
    private static func cell(for item: StreamItem, in stream: CommentStream) -> UICollectionViewCell? {
        let view = stream.collectionView
        view.layoutIfNeeded()
        for section in 0..<view.numberOfSections {
            for index in 0..<view.numberOfItems(inSection: section) {
                let path = IndexPath(item: index, section: section)
                guard let link = view.cellForItem(at: path) as? CommentStreamLinkCell, link.content != nil else { continue }
                let wanted = item == .seeAll ? "comments.seeAll" : "comments.earlier"
                if link.content?.identifier == wanted { return link }
            }
        }
        return nil
    }

    /// ⚠️ POPULAR FITS ITS ROOM, whole threads only, "See all" last — on a
    /// Pro Max, a Pro and an SE, measured against the device's own room.
    @Test(arguments: [Self.proMax, Self.pro, Self.se])
    func popularShowsTheWholeThreadsThatFitThenSeeAll(_ size: CGSize) async {
        let (controller, window) = panel(PagedComments(count: 40, pageSize: 40), size: size)
        defer { window.isHidden = true }
        let stream = controller.popular
        #expect(await settle { Self.laidOut(stream) && stream.debugItems.last == .seeAll })
        let items = stream.debugItems
        #expect(items.first == .caption, "\(size): the caption leads")
        let shown = Self.topLevelCount(items)
        #expect(shown > 0 && shown < 40, "\(size): \(shown) threads")
        #expect(items.filter { $0 == .seeAll }.count == 1)
        // The rows realise their own heights a turn later.
        #expect(await settle { Self.rowsHeight(stream, controller) <= stream.debugCutRoom + 1 },
                "\(size): \(Self.rowsHeight(stream, controller)) of rows in a room of \(stream.debugCutRoom)")
        // Nothing paged: the room is filled by Popular's first page alone.
        try? await Task.sleep(for: .milliseconds(200))
        #expect(stream.debugCommentCount == 40)
    }

    /// A Pro Max holds more threads than an SE.
    @Test func aLargerRoomHoldsMoreThreads() async {
        func shown(_ size: CGSize) async -> Int {
            let (controller, window) = panel(PagedComments(count: 40, pageSize: 40), size: size)
            defer { window.isHidden = true }
            let stream = controller.popular
            _ = await settle { Self.laidOut(stream) && stream.debugItems.last == .seeAll }
            return Self.topLevelCount(stream.debugItems)
        }
        let large = await shown(Self.proMax)
        let small = await shown(Self.se)
        #expect(large > small, "Pro Max \(large), SE \(small)")
    }

    /// When it all fits: every comment, no "See all", the stream no taller
    /// than its room — it doesn't scroll, and the edge hand-off takes any
    /// vertical drag on it.
    @Test func aPopularThatFitsShowsEverythingWithoutSeeAll() async {
        let (controller, window) = panel(PagedComments(count: 3, pageSize: 40))
        defer { window.isHidden = true }
        let stream = controller.popular
        #expect(await settle { Self.laidOut(stream) && Self.topLevelCount(stream.debugItems) == 3 })
        #expect(!stream.debugItems.contains(.seeAll))
        #expect(stream.streamIsAtTop && stream.streamIsAtBottom, "a stream that fits is at both edges")
    }

    /// ⚠️ THE CAPTION IS NEVER CUT, AND POPULAR NEVER SHOWS ZERO: taller than
    /// the room, the caption whole, then the first thread, then "See all".
    @Test(arguments: [Self.pro, Self.se])
    func aLongCaptionShowsTheFirstThreadAndSeeAll(_ size: CGSize) async {
        let caption = Array(
            repeating: "A caption that goes on and on about the light over the harbour at dawn.", count: 40
        ).joined(separator: " ")
        let (controller, window) = panel(PagedComments(count: 20, pageSize: 20), size: size, caption: caption)
        defer { window.isHidden = true }
        let stream = controller.popular
        #expect(await settle { Self.laidOut(stream) && stream.debugItems.last == .seeAll })
        let items = stream.debugItems
        #expect(items.first == .caption)
        #expect(Self.topLevelCount(items) == 1, "\(size): \(items)")
    }

    /// Popular is not paged on this page: its first ranked page only.
    @Test func popularAsksForItsFirstPageOnly() async {
        let provider = PagedComments(count: 60, pageSize: 12)
        let (controller, window) = panel(provider)
        defer { window.isHidden = true }
        let stream = controller.popular
        #expect(await settle { Self.laidOut(stream) && stream.debugItems.last == .seeAll })
        // Scrolled to its end, nothing more is asked.
        let view = stream.collectionView
        stream.debugScroll(to: max(-view.adjustedContentInset.top,
                                   view.contentSize.height + view.adjustedContentInset.bottom - view.bounds.height),
                           userScroll: true)
        view.layoutIfNeeded()
        try? await Task.sleep(for: .milliseconds(300))
        #expect(await provider.rankedPagesAsked == 1)
    }

    /// "See all n comments" turns to Recent, and says the post's count.
    @Test func seeAllTurnsToRecent() async throws {
        let (controller, window) = panel(PagedComments(count: 40, pageSize: 40))
        defer { window.isHidden = true }
        controller.seedCommentCount(40)
        let stream = controller.popular
        #expect(await settle { Self.laidOut(stream) && stream.debugItems.last == .seeAll })
        // The last row, brought on screen.
        let view = stream.collectionView
        view.contentOffset.y = max(-view.adjustedContentInset.top,
                                   view.contentSize.height + view.adjustedContentInset.bottom - view.bounds.height)
        let cell = try #require(await settleCell(.seeAll, in: stream))
        #expect(cell.content?.title == "See all 40 comments")
        _ = cell.accessibilityActivate()
        #expect(await settle { controller.visibleStreamKind == .recent })
    }

    private func settleCell(_ item: StreamItem, in stream: CommentStream) async -> CommentStreamLinkCell? {
        _ = await settle { Self.cell(for: item, in: stream) != nil }
        return Self.cell(for: item, in: stream) as? CommentStreamLinkCell
    }

    /// Recent in its room: its newest page, "Earlier comments" at its top;
    /// older pages only on the row's tap — never by themselves as the reader
    /// scrolls up — and once all is in, the row goes and the caption is the
    /// top.
    @Test func recentLoadsOlderPagesOnlyOnTheRowsTap() async throws {
        let provider = PagedComments(count: 30, pageSize: 12)
        let (controller, window) = panel(provider)
        defer { window.isHidden = true }
        controller.showStream(.recent, animated: false)
        let stream = controller.recent
        #expect(await settle { Self.laidOut(stream) && stream.debugItems.first == .earlier })
        #expect(!stream.debugItems.contains(.caption), "the caption waits above the older pages")
        // Up to the top: nothing loads by itself.
        stream.debugScroll(to: -stream.collectionView.adjustedContentInset.top, userScroll: true)
        stream.collectionView.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(300))
        #expect(await provider.olderPagesAsked == 0)
        #expect(stream.debugCommentCount == 12)

        for loaded in [24, 30] {
            stream.debugScroll(to: -stream.collectionView.adjustedContentInset.top, userScroll: true)
            let row = try #require(await settleCell(.earlier, in: stream), "no Earlier comments row")
            _ = row.accessibilityActivate()
            #expect(await settle { stream.debugCommentCount == loaded }, "\(stream.debugCommentCount) loaded")
        }
        #expect(await provider.olderPagesAsked == 2)
        #expect(await settle { stream.debugItems.first == .caption }, "the caption is the top once all is in")
        #expect(!stream.debugItems.contains(.earlier))
    }

    /// ⚠️ AN OLDER PAGE LANDS WITHOUT MOVING THE LIST: the row on screen under
    /// "Earlier comments" stays where it was.
    @Test func anOlderPageLandsWithoutMovingTheList() async throws {
        let provider = PagedComments(count: 30, pageSize: 12)
        let (controller, window) = panel(provider)
        defer { window.isHidden = true }
        controller.showStream(.recent, animated: false)
        let stream = controller.recent
        #expect(await settle { Self.laidOut(stream) && stream.debugItems.first == .earlier })
        let view = stream.collectionView
        stream.debugScroll(to: -view.adjustedContentInset.top, userScroll: true)
        let row = try #require(await settleCell(.earlier, in: stream))
        // The first comment under the row, and where it stands on screen.
        let firstComment = try #require(stream.debugItems.first { if case .comment = $0 { true } else { false } })
        func screenY() -> CGFloat? {
            view.layoutIfNeeded()
            guard let index = stream.debugItems.firstIndex(of: firstComment) else { return nil }
            // One section with the day pills off (no thread chrome here).
            let path = IndexPath(item: index, section: 0)
            return view.layoutAttributesForItem(at: path).map { $0.frame.minY - view.contentOffset.y }
        }
        let before = try #require(screenY())
        _ = row.accessibilityActivate()
        #expect(await settle { stream.debugCommentCount == 24 })
        // The hold refines over a few layout passes (the rows realised at the
        // new offset settle their heights): read once it has stayed.
        _ = await settle { screenY().map { abs($0 - before) < 1 } ?? false }
        let after = try #require(screenY())
        #expect(abs(after - before) < 1, "the list moved: \(before) → \(after)")
    }

    /// A failed older page: a retry in place, on the same row.
    @Test func aFailedOlderPageOffersARetryInPlace() async throws {
        let provider = PagedComments(count: 30, pageSize: 12)
        await provider.setFailsOlderPages(true)
        let (controller, window) = panel(provider)
        defer { window.isHidden = true }
        controller.showStream(.recent, animated: false)
        let stream = controller.recent
        #expect(await settle { Self.laidOut(stream) && stream.debugItems.first == .earlier })
        stream.debugScroll(to: -stream.collectionView.adjustedContentInset.top, userScroll: true)
        let row = try #require(await settleCell(.earlier, in: stream))
        _ = row.accessibilityActivate()
        #expect(await settle { (Self.cell(for: .earlier, in: stream) as? CommentStreamLinkCell)?.content?.state == .failed })
        #expect(stream.debugCommentCount == 12)
        await provider.setFailsOlderPages(false)
        let retry = try #require(await settleCell(.earlier, in: stream))
        _ = retry.accessibilityActivate()
        #expect(await settle { stream.debugCommentCount == 24 })
    }

    /// The comments sheet reads in its room too: Popular cut, "See all".
    @Test func theSheetCutsPopularToItsRoom() async {
        let detail = PostDetailViewController(
            viewModel: PostDetailViewModel(postID: PostID("p"), repository: NoPostFeed(), commentsProvider: PagedComments(count: 40, pageSize: 40)),
            imagePipeline: ImagePipeline(fetcher: PlaceholderImageFetcher())
        )
        detail.seedCaption("A post", timestamp: "2h", authorName: "Ava Moreau")
        SnapCommentsSheetViewController.prepare(detail, commentCount: 40)
        let content = SnapCommentsSheetViewController(panel: detail, walletBadge: nil, onWalletTap: nil)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: Self.pro.width, height: 520))
        window.rootViewController = content
        window.isHidden = false
        defer { window.isHidden = true }
        content.composerBottomInset = 34
        content.loadViewIfNeeded()
        content.view.layoutIfNeeded()
        content.applyPanelInsets()
        let stream = detail.popular
        #expect(await settle { Self.laidOut(stream) && stream.debugItems.last == .seeAll })
        #expect(await settle { Self.rowsHeight(stream, detail) <= stream.debugCutRoom + 1 })
    }

    /// Off the vertical feed (no page swipe: the published text post's
    /// sheet), nothing is cut, and Recent pages as before.
    @Test func withoutAFeedAroundNothingIsCut() async {
        let (controller, window) = panel(PagedComments(count: 40, pageSize: 40), inFeed: false)
        defer { window.isHidden = true }
        #expect(await settle { Self.laidOut(controller.popular) && Self.topLevelCount(controller.popular.debugItems) == 40 })
        #expect(!controller.popular.debugItems.contains(.seeAll))
        #expect(!controller.recent.debugItems.contains(.earlier))
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
        #expect(fitted > 70, "the two-line body measured \(fitted)")
        // ⚠️ AND DRAWN WHOLE where it lands (the owner's device, 2026-11-02):
        // laid out at the measured frame, the body is two lines — never one
        // line under an ellipsis in a row two lines tall.
        cell.frame = CGRect(x: 0, y: 0, width: 370, height: fitted)
        cell.setNeedsLayout()
        cell.layoutIfNeeded()
        let label = cell.row.bodyTextLabel
        #expect(label.bounds.height > oneLine * 1.5, "the body drew \(label.bounds.height) in a row of \(fitted)")
        #expect(abs(label.preferredMaxLayoutWidth - label.bounds.width) < 1,
                "the body was told \(label.preferredMaxLayoutWidth) for a width of \(label.bounds.width)")
    }

    /// The body's width comes from the row's: less the indent, the disc and
    /// the gap — never the label's frame from a previous pass.
    @Test func theBodyWidthIsTheRowsLessItsColumn() {
        #expect(CommentRowView.bodyWidth(rowWidth: 370, indent: 0, avatar: 39) == 370 - 39 - Spacing.sm)
        #expect(CommentRowView.bodyWidth(rowWidth: 370, indent: 47, avatar: 39) == 370 - 47 - 39 - Spacing.sm)
    }
}
