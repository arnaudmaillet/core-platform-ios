import CoreModels
import DesignSystem
import MediaCore
import MediaCoreFixtures
import Testing
import UIKit
@testable import Feed
@testable import ThreadKit

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

private func comment(_ index: Int, parent: String? = nil, by author: String = "other") -> CommentEntry {
    CommentEntry(
        id: parent.map { "\($0)-r\(index)" } ?? "c\(index)", authorID: ProfileID(author), authorName: "Ava Moreau",
        authorHandle: "ava", body: "Comment \(index)", createdAt: Date(timeIntervalSinceNow: -Double(index) * 60),
        parentID: parent
    )
}

/// `count` comments, newest first (`c0` the newest), in Recent's pages of
/// `pageSize`; Popular ranks them the other way round, oldest first, so the
/// two tabs are told apart by their first rows.
private actor PagedComments: CommentsProviding {
    let all: [CommentEntry]
    let pageSize: Int
    /// What the opener already holds: a preview of the newest few (#2036).
    nonisolated let cached: [CommentEntry]?
    private(set) var recentPagesAsked = 0

    init(count: Int, pageSize: Int, cachedPreview: Int? = nil) {
        let all = (0..<count).map { comment($0) }
        self.all = all
        self.pageSize = pageSize
        cached = cachedPreview.map { Array(all.prefix($0)) }
    }

    nonisolated func cachedTopComments(for postID: PostID) -> [CommentEntry]? { cached }

    private func page(of list: [CommentEntry], after token: String?, prefix: String) -> CommentPage {
        let start = token.flatMap { Int($0.dropFirst(prefix.count)) } ?? 0
        let end = min(list.count, start + pageSize)
        return CommentPage(entries: Array(list[start..<end]), nextPageToken: end < list.count ? "\(prefix)\(end)" : nil)
    }

    func loadComments(for postID: PostID) async throws -> [CommentEntry] { Array(all.prefix(pageSize)) }

    func loadCommentsPage(for postID: PostID, after pageToken: String?) async throws -> CommentPage {
        recentPagesAsked += 1
        return page(of: all, after: pageToken, prefix: "recent-")
    }

    func loadCommentsPage(for postID: PostID, after pageToken: String?, order: CommentSortOrder) async throws -> CommentPage {
        guard order != .recent else { return try await loadCommentsPage(for: postID, after: pageToken) }
        return page(of: all.reversed(), after: pageToken, prefix: "ranked-")
    }

    func addComment(_ body: String, to postID: PostID, parentID: String?, commentID: String) async throws -> CommentEntry {
        CommentEntry(
            id: commentID, authorID: ProfileID("me"), authorName: "Me", authorHandle: "me",
            body: body, createdAt: Date(), parentID: parentID
        )
    }
}

/// **The comments' two tabs (#2007).** Popular, the server's ranking, rests at
/// its top and is the tab a panel opens on once the post has enough comments
/// (`CommentSortPolicy`); Recent reads as a conversation — oldest above, the
/// newest at its end, where it rests — and its older pages land above without
/// moving what is on screen. Each keeps its own position.
@MainActor
struct CommentTabsTests {
    private static let looks = 3_000

    private func settle(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<Self.looks where !condition() {
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    private func panel(
        _ provider: PagedComments, seeded: Int64? = nil
    ) -> (PostDetailViewController, UIWindow) {
        let controller = PostDetailViewController(
            viewModel: PostDetailViewModel(postID: PostID("p"), repository: NoPostFeed(), commentsProvider: provider),
            imagePipeline: ImagePipeline(fetcher: PlaceholderImageFetcher())
        )
        controller.seedCommentCount(seeded)
        // ⚠️ NOT THE SYSTEM KEYBOARD. Its guide is app-wide: a suite running
        // alongside that focuses a field (on CI, with no hardware keyboard)
        // raised this composer, and Recent's inset with it, by the keyboard's
        // height — 228.67pt, the same on every starved run (#2392). The
        // keyboard tests drive the rise themselves (`syncKeyboardRise`).
        controller.setComposerTracksKeyboard(false)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = controller
        window.isHidden = false
        controller.seedCaption("A text post", timestamp: "2h", authorName: "Ava Moreau")
        return (controller, window)
    }

    /// The comment rows' bodies on `stream`, top to bottom.
    private static func bodies(_ stream: CommentStream) -> [String] {
        stream.collectionView.layoutIfNeeded()
        return stream.collectionView.indexPathsForVisibleItems.sorted().compactMap {
            stream.collectionView.cellForItem(at: $0).flatMap(PostDetailViewController.commentRow(in:))?
                .bodyTextLabel.text
        }
    }

    private static func loaded(_ stream: CommentStream) -> Bool {
        stream.commentsLoaded && !bodies(stream).isEmpty
    }

    private static func topOffset(_ view: UIScrollView) -> CGFloat { -view.adjustedContentInset.top }

    private static func tailOffset(_ view: UIScrollView) -> CGFloat {
        max(topOffset(view), view.contentSize.height + view.adjustedContentInset.bottom - view.bounds.height)
    }

    // MARK: - The threshold

    /// ⚠️ NO THRESHOLD (#2287, the owner 2026-11-11: "Popular toujours"):
    /// a short thread has both tabs from the start, opens on Popular, and
    /// pages — no Recent first, waiting for a count.
    @Test func aShortThreadHasBothTabsAndOpensOnPopular() async {
        let (controller, window) = panel(PagedComments(count: 5, pageSize: 20))
        defer { window.isHidden = true }
        #expect(await settle { Self.loaded(controller.recent) })
        #expect(controller.showsPopular)
        #expect(controller.visibleStreamKind == .popular)
        #expect(controller.streamPager.isPagingEnabled, "the tabs don't page")
        #expect(controller.popular.pageView.superview != nil, "Popular isn't mounted")
    }

    /// A thread opens the panel on Popular, its first answer loaded there.
    @Test func aThreadOpensThePanelOnPopular() async {
        let (controller, window) = panel(PagedComments(count: 10, pageSize: 20))
        defer { window.isHidden = true }
        #expect(await settle { Self.loaded(controller.popular) })
        #expect(controller.showsPopular)
        #expect(controller.visibleStreamKind == .popular)
        #expect(controller.streamPager.isPagingEnabled)
    }

    /// A preview of a few comments on screen first does not decide it: the
    /// first page past the threshold still opens the panel on Popular.
    @Test func aPreviewOfAFewDoesNotKeepThePanelOnRecent() async {
        let (controller, window) = panel(PagedComments(count: 30, pageSize: 30, cachedPreview: 2))
        defer { window.isHidden = true }
        #expect(await settle { controller.showsPopular }, "Popular never came")
        #expect(controller.visibleStreamKind == .popular)
    }

    /// The opener's count decides it before anything has loaded.
    @Test func theOpenersCountOpensOnPopularFromTheFirstFrame() {
        let (controller, window) = panel(PagedComments(count: 40, pageSize: 20), seeded: 40)
        defer { window.isHidden = true }
        #expect(controller.showsPopular)
        #expect(controller.visibleStreamKind == .popular)
    }

    // MARK: - Each tab at its own end

    /// Popular in the server's ranking, from its top; Recent oldest above,
    /// the newest at its end — where it rests.
    @Test func popularRestsAtItsTopAndRecentAtItsEnd() async {
        let (controller, window) = panel(PagedComments(count: 30, pageSize: 30))
        defer { window.isHidden = true }
        #expect(await settle { Self.loaded(controller.popular) && Self.loaded(controller.recent) })
        let popular = controller.popular.collectionView
        let recent = controller.recent.collectionView
        #expect(abs(popular.contentOffset.y - Self.topOffset(popular)) < 1, "Popular left its top")
        #expect(Self.bodies(controller.popular).first == "Comment 29", "Popular is not the server's ranking")
        #expect(await settle { abs(recent.contentOffset.y - Self.tailOffset(recent)) < 1 },
                "Recent is not at its end: \(recent.contentOffset.y) against \(Self.tailOffset(recent))")
        #expect(Self.bodies(controller.recent).last == "Comment 0", "Recent's newest is not at its end")
    }

    /// The conversation's order: threads oldest first, each with its replies
    /// under it in their own order.
    @Test func recentReadsOldestFirst() {
        let models = [comment(0), comment(1), comment(2, parent: "c1"), comment(3, parent: "c1"), comment(4)]
            .map { CommentDisplayModel(entry: $0) }
        #expect(CommentStream.conversationOrder(models).map(\.id) == ["c4", "c1", "c1-r2", "c1-r3", "c0"])
    }

    /// ⚠️ OLDER PAGES LAND ABOVE WITHOUT MOVING WHAT IS ON SCREEN: the row
    /// at the top of Recent's viewport is where it was once they are in.
    @Test func olderPagesLandAboveRecentWithoutMovingTheRows() async throws {
        let provider = PagedComments(count: 60, pageSize: 20)
        let (controller, window) = panel(provider)
        defer { window.isHidden = true }
        #expect(await settle { Self.loaded(controller.recent) })
        controller.showStream(.recent, animated: false)
        let recent = controller.recent.collectionView
        let before = controller.recent.debugCommentCount
        // The reader goes up to the oldest rows loaded.
        controller.debugScroll(to: Self.topOffset(recent), userScroll: true)
        recent.layoutIfNeeded()
        let anchor = try #require(recent.indexPathsForVisibleItems.sorted().first { path in
            recent.cellForItem(at: path).flatMap(PostDetailViewController.commentRow(in:)) != nil
        })
        let cell = try #require(recent.cellForItem(at: anchor).flatMap(PostDetailViewController.commentRow(in:)))
        let body = try #require(cell.bodyTextLabel.text)
        let onScreen = try #require(recent.layoutAttributesForItem(at: anchor)).frame.minY - recent.contentOffset.y

        #expect(await settle { controller.recent.debugCommentCount > before }, "no older page landed")
        recent.layoutIfNeeded()
        let moved = try #require(recent.indexPathsForVisibleItems.first { path in
            recent.cellForItem(at: path).flatMap(PostDetailViewController.commentRow(in:))?.bodyTextLabel.text == body
        }, "the row left the screen")
        let now = try #require(recent.layoutAttributesForItem(at: moved)).frame.minY - recent.contentOffset.y
        #expect(abs(now - onScreen) < 1, "the row moved by \(now - onScreen)")
    }

    // MARK: - No jump, no auto-scroll

    /// Each tab keeps its own position: Recent left part-way up, Popular
    /// part-way down, and back again.
    @Test func eachTabKeepsItsPosition() async {
        let (controller, window) = panel(PagedComments(count: 30, pageSize: 30))
        defer { window.isHidden = true }
        #expect(await settle { Self.loaded(controller.popular) && Self.loaded(controller.recent) })
        let popular = controller.popular.collectionView
        let recent = controller.recent.collectionView

        // Where each is left once its rows there have realised: a jump of
        // 300 pt refines a few estimated heights, which is not a tab's doing.
        func leave(_ view: UICollectionView, at offset: CGFloat) -> CGFloat {
            controller.debugScroll(to: offset, userScroll: true)
            view.layoutIfNeeded()
            view.layoutIfNeeded()
            return view.contentOffset.y
        }
        controller.showStream(.recent, animated: false)
        let recentLeft = leave(recent, at: Self.tailOffset(recent) - 300)
        controller.showStream(.popular, animated: false)
        let popularLeft = leave(popular, at: Self.topOffset(popular) + 250)
        controller.view.setNeedsLayout()
        controller.view.layoutIfNeeded()
        controller.showStream(.recent, animated: false)
        controller.view.setNeedsLayout()
        controller.view.layoutIfNeeded()

        #expect(abs(recent.contentOffset.y - recentLeft) < 0.5, "Recent moved: \(recent.contentOffset.y)")
        #expect(abs(popular.contentOffset.y - popularLeft) < 0.5, "Popular moved: \(popular.contentOffset.y)")
    }

    /// The way back heads for the visible tab's start: Recent's newest,
    /// Popular's top.
    @Test func theWayBackTargetsTheVisibleTabsStart() async {
        let (controller, window) = panel(PagedComments(count: 30, pageSize: 30))
        defer { window.isHidden = true }
        #expect(await settle { Self.loaded(controller.popular) && Self.loaded(controller.recent) })
        let popular = controller.popular.collectionView
        let recent = controller.recent.collectionView

        controller.debugScroll(to: Self.topOffset(popular) + 400, userScroll: true)
        #expect(!controller.scrollAwayReturnsDown)
        controller.scrollToStart(animated: false)
        #expect(abs(popular.contentOffset.y - Self.topOffset(popular)) < 0.5)

        controller.showStream(.recent, animated: false)
        controller.debugScroll(to: Self.topOffset(recent), userScroll: true)
        #expect(controller.scrollAwayReturnsDown)
        controller.scrollToStart(animated: false)
        #expect(abs(recent.contentOffset.y - Self.tailOffset(recent)) < 0.5)
    }

    /// A comment sent from Popular shows at its top as the viewer's own and at
    /// Recent's end; the tab does not change, and Recent, off screen, takes
    /// it without animating.
    @Test func aCommentSentFromPopularLandsInBothAndTheTabStays() async {
        let (controller, window) = panel(PagedComments(count: 12, pageSize: 20))
        defer { window.isHidden = true }
        #expect(await settle { Self.loaded(controller.popular) && Self.loaded(controller.recent) })

        controller.debugSend("Mine")
        #expect(await settle { Self.bodies(controller.popular).first == "Mine" }, "\(Self.bodies(controller.popular))")
        #expect(await settle { Self.bodies(controller.recent).last == "Mine" }, "\(Self.bodies(controller.recent))")
        #expect(controller.visibleStreamKind == .popular, "the tab changed")
        #expect(!controller.recent.debugLastApplyAnimated, "the tab off screen animated")
    }

    // MARK: - The selector

    /// The selector and the pager are one state (#2007): a tap shows the tab,
    /// a swipe of the streams moves the pill, a scrub of the pill moves the
    /// streams.
    @Test func theSelectorAndThePagerStayInStep() async {
        let (controller, window) = panel(PagedComments(count: 12, pageSize: 20))
        defer { window.isHidden = true }
        #expect(await settle { Self.loaded(controller.popular) })
        let selector = CommentTabsSelector()
        selector.bind(to: controller)
        #expect(selector.tabBar.selectedIndex == PostDetailViewController.popularPage)

        selector.tabBar.debugSimulateTap(at: PostDetailViewController.recentPage)
        #expect(await settle { controller.visibleStreamKind == .recent }, "a tap did not show Recent")

        let pager = controller.streamPager.pagingScrollView
        pager.contentOffset.x = pager.bounds.width * 0.3
        #expect(selector.tabBar.selectedIndex == PostDetailViewController.popularPage, "the pill did not follow the swipe")

        selector.tabBar.onScrub?(0.75)
        #expect(abs(pager.contentOffset.x - pager.bounds.width * 0.75) < 1, "the streams did not follow the pill")
    }

    // MARK: - The keyboard

    /// ⚠️ RECENT RIDES THE KEYBOARD, as a conversation does (the owner,
    /// 2026-11-01): its newest row stays just above the risen field. Popular
    /// stays where it is for a plain tap in the field — no reply armed (the
    /// owner, 2026-11-18, #2487); and the two hold their own insets, so either
    /// tab is right with the keyboard up.
    @Test func recentRidesTheKeyboardAndPopularStays() async {
        let (controller, window) = panel(PagedComments(count: 30, pageSize: 30))
        defer { window.isHidden = true }
        controller.setEngagedInsets(top: 100, bottomInset: 34)
        #expect(await settle { Self.loaded(controller.popular) && Self.loaded(controller.recent) })
        let popular = controller.popular.collectionView
        let recent = controller.recent.collectionView
        let popularBefore = (popular.contentInset.bottom, popular.contentOffset.y)
        let recentInset = recent.contentInset.bottom
        #expect(abs(recent.contentOffset.y - Self.tailOffset(recent)) < 1)

        controller.recent.syncKeyboardRise(300)
        controller.popular.syncKeyboardRise(300)
        #expect(abs(recent.contentInset.bottom - (recentInset + 300)) < 0.5)
        #expect(abs(recent.contentOffset.y - Self.tailOffset(recent)) < 1, "Recent's newest went under the keyboard")
        #expect(popular.contentInset.bottom == popularBefore.0 && popular.contentOffset.y == popularBefore.1, "Popular moved")

        controller.recent.syncKeyboardRise(0)
        #expect(abs(recent.contentInset.bottom - recentInset) < 0.5)
        #expect(abs(recent.contentOffset.y - Self.tailOffset(recent)) < 1)
    }

    /// A reader further up keeps the rows they were reading on screen as the
    /// keyboard comes up: the offset rises by the same amount.
    @Test func aReaderFurtherUpKeepsTheirRowsAsTheKeyboardRises() async {
        let (controller, window) = panel(PagedComments(count: 30, pageSize: 30))
        defer { window.isHidden = true }
        controller.setEngagedInsets(top: 100, bottomInset: 34)
        #expect(await settle { Self.loaded(controller.popular) && Self.loaded(controller.recent) })
        controller.showStream(.recent, animated: false)
        let recent = controller.recent.collectionView
        controller.debugScroll(to: Self.tailOffset(recent) - 600, userScroll: true)
        let before = recent.contentOffset.y

        controller.recent.syncKeyboardRise(250)
        #expect(abs(recent.contentOffset.y - (before + 250)) < 0.5)
    }

    // MARK: - A reply on Popular rides the keyboard (#2487)

    /// The visible bottom of `list`'s rows: the composer's top, in content.
    private static func visibleBottom(_ list: UIScrollView) -> CGFloat {
        list.contentOffset.y + list.bounds.height - list.adjustedContentInset.bottom
    }

    /// The frame of Popular's row for comment `id`, in its content.
    private static func frame(of id: String, in stream: CommentStream) -> CGRect? {
        stream.collectionView.layoutIfNeeded()
        return stream.streamDataSource.indexPath(for: .comment(id))
            .flatMap { stream.collectionView.layoutAttributesForItem(at: $0)?.frame }
    }

    /// Popular's first comment whose row ends below the composer's top at
    /// rest: the one a keyboard would hide.
    private static func firstRowUnderTheComposer(_ stream: CommentStream) -> String? {
        let bottom = visibleBottom(stream.collectionView)
        return (0..<30).reversed().map { "c\($0)" }.first { (frame(of: $0, in: stream)?.maxY ?? 0) > bottom }
    }

    /// A Reply on Popular's comment `id`, as its row arms it: the field
    /// focused, with no system keyboard (`raisesNoKeyboard`).
    private func reply(_ controller: PostDetailViewController, to index: Int) {
        controller.composeBar.debugTextView.raisesNoKeyboard()
        controller.popular.enterReplyState(for: CommentDisplayModel(entry: comment(index)))
    }

    /// A reply rides the keyboard on Popular as Recent does: the inset grows
    /// by the rise, the rows rise with it — never past the answered comment's
    /// top at the room's top (#2487, decided 2026-11-25) — and the keyboard
    /// gone, Popular is back at its top.
    @Test func aReplyOnPopularRidesTheKeyboard() async throws {
        let (controller, window) = panel(PagedComments(count: 30, pageSize: 30))
        defer {
            controller.composeBar.debugTextView.resignFirstResponder()
            window.isHidden = true
        }
        controller.setEngagedInsets(top: 100, bottomInset: 34)
        #expect(await settle { Self.loaded(controller.popular) && Self.loaded(controller.recent) })
        let popular = controller.popular.collectionView
        let inset = popular.contentInset.bottom
        let offset = popular.contentOffset.y
        // Comment 29 leads Popular: high up, it rises until its top meets
        // the room's, and stays in view.
        reply(controller, to: 29)
        let top = try #require(Self.frame(of: "c29", in: controller.popular)).minY - popular.adjustedContentInset.top

        controller.popular.syncKeyboardRise(300)
        #expect(abs(popular.contentInset.bottom - (inset + 300)) < 0.5)
        let risen = min(offset + 300, top)
        #expect(risen > offset + 0.5, "Popular's rows did not rise with the keyboard")
        #expect(abs(popular.contentOffset.y - risen) < 0.5, "the answered comment left the view")

        controller.popular.syncKeyboardRise(0)
        #expect(abs(popular.contentInset.bottom - inset) < 0.5)
        #expect(abs(popular.contentOffset.y - Self.topOffset(popular)) < 0.5, "Popular is not back at its top")
    }

    /// The comment being answered ends just above the field: a row the
    /// keyboard would cover scrolls in, past the rise, as far as it needs.
    @Test func theAnsweredCommentEndsAboveTheField() async throws {
        let (controller, window) = panel(PagedComments(count: 30, pageSize: 30))
        defer {
            controller.composeBar.debugTextView.resignFirstResponder()
            window.isHidden = true
        }
        controller.setEngagedInsets(top: 100, bottomInset: 34)
        #expect(await settle { Self.loaded(controller.popular) && Self.loaded(controller.recent) })
        let stream = controller.popular
        let id = try #require(Self.firstRowUnderTheComposer(stream))
        let offset = stream.collectionView.contentOffset.y
        reply(controller, to: try #require(Int(id.dropFirst())))

        stream.syncKeyboardRise(300)
        let row = try #require(Self.frame(of: id, in: stream))
        #expect(row.maxY <= Self.visibleBottom(stream.collectionView) + 0.5, "the answered comment is under the keys")
        #expect(stream.collectionView.contentOffset.y > offset + 300, "the row needed more than the rise")
        stream.syncKeyboardRise(0)
    }

    /// A reply cancelled with the keyboard up (the chip's ✕): Popular stays
    /// risen until the keyboard goes, then rests at its top.
    @Test func aCancelledReplyStaysRisenUntilTheKeyboardGoes() async {
        let (controller, window) = panel(PagedComments(count: 30, pageSize: 30))
        defer {
            controller.composeBar.debugTextView.resignFirstResponder()
            window.isHidden = true
        }
        controller.setEngagedInsets(top: 100, bottomInset: 34)
        #expect(await settle { Self.loaded(controller.popular) && Self.loaded(controller.recent) })
        let popular = controller.popular.collectionView
        let inset = popular.contentInset.bottom
        reply(controller, to: 29)
        controller.popular.syncKeyboardRise(300)
        let risen = popular.contentOffset.y

        controller.clearReplyState()
        controller.popular.syncKeyboardRise(310)
        #expect(abs(popular.contentInset.bottom - (inset + 310)) < 0.5, "the cancelled reply's inset jumped back")
        #expect(popular.contentOffset.y >= risen, "the rows jumped back while typing")

        controller.popular.syncKeyboardRise(0)
        #expect(abs(popular.contentOffset.y - Self.topOffset(popular)) < 0.5)
        // The next plain tap in the field moves nothing.
        controller.popular.syncKeyboardRise(300)
        #expect(abs(popular.contentInset.bottom - inset) < 0.5, "a plain tap moved Popular")
    }

    /// Popular's cut (#2298) is decided on the resting room: a reply's
    /// keyboard changes its inset, never the threads it shows.
    @Test func popularsCutStaysWithTheKeyboardUp() async {
        let (controller, window) = panel(PagedComments(count: 30, pageSize: 30))
        defer {
            controller.composeBar.debugTextView.resignFirstResponder()
            window.isHidden = true
        }
        controller.cutStreamsToRoom()
        controller.setEngagedInsets(top: 100, bottomInset: 34)
        #expect(await settle { Self.loaded(controller.popular) && controller.popular.debugItems.last == .seeAll })
        let items = controller.popular.debugItems
        let room = controller.popular.debugCutRoom
        reply(controller, to: 29)

        controller.popular.syncKeyboardRise(300)
        controller.popular.refitCut()
        #expect(controller.popular.debugItems == items, "the keyboard cut Popular again")
        #expect(controller.popular.debugCutRoom == room)
        controller.popular.syncKeyboardRise(0)
    }

    /// The rule alone: a plain tap never rides; a reply rides from its rise
    /// until the keyboard is down, cancelled or not; the way down is followed
    /// once, to rest.
    @Test func theReplyRiseRule() {
        var rise = ReplyKeyboardRise()
        let plainTap = rise.follows(rise: 300, replying: false)
        let otherTab = rise.follows(rise: 300, replying: true)
        let down = rise.follows(rise: 0, replying: false)
        #expect(!plainTap, "a plain tap rode")
        #expect(!otherTab, "a reply armed on the other tab rode")
        #expect(!down)
        rise.rowID = "c1"
        let reply = rise.follows(rise: 300, replying: true)
        let cancelled = rise.follows(rise: 280, replying: false)
        let wayBack = rise.follows(rise: 0, replying: false)
        #expect(reply)
        #expect(cancelled, "a cancelled reply let go with the keyboard up")
        #expect(wayBack, "the way back to rest was not followed")
        #expect(!rise.isRiding && rise.rowID == nil)
        let after = rise.follows(rise: 0, replying: false)
        #expect(!after)
    }

    /// A reply armed waits for its keys: a layout pass before they come (the
    /// sheet expanding for the reply, #2153) keeps it; a reply let go before
    /// them is forgotten.
    @Test func anArmedReplyWaitsForItsKeys() {
        var rise = ReplyKeyboardRise()
        rise.rowID = "c1"
        let beforeTheKeys = rise.follows(rise: 0, replying: true)
        #expect(!beforeTheKeys && rise.rowID == "c1", "a layout pass before the keys dropped the reply")
        let keys = rise.follows(rise: 300, replying: true)
        #expect(keys)
        _ = rise.follows(rise: 0, replying: true)
        #expect(rise.rowID == nil, "the reply outlived its keyboard")
        rise.rowID = "c2"
        _ = rise.follows(rise: 0, replying: false)
        #expect(rise.rowID == nil, "a reply let go before its keys was kept")
    }

    // MARK: - A reply rides the comments sheet's detached composer (#2487)

    /// The panel as the comments sheet sets it: its composer does not ride
    /// the keys, a detached one edits over them (`prepare`).
    private func sheetPanel() async -> (PostDetailViewController, UIWindow) {
        let (controller, window) = panel(PagedComments(count: 30, pageSize: 30))
        controller.streamsRideKeyboard = false
        controller.setEngagedInsets(top: 100, bottomInset: 34)
        #expect(await settle { Self.loaded(controller.popular) && Self.loaded(controller.recent) })
        return (controller, window)
    }

    /// A plain tap in the field moves nothing under the detached composer,
    /// on either tab (the owner, 2026-11-04, kept 2026-11-25).
    @Test func underTheDetachedComposerAPlainTapMovesNeitherTab() async {
        let (controller, window) = await sheetPanel()
        defer { window.isHidden = true }
        let lists = controller.streams.map(\.collectionView)
        let before = lists.map { ($0.contentInset.bottom, $0.contentOffset.y) }

        controller.followDetachedComposer(rise: 300)
        controller.view.setNeedsLayout()
        controller.view.layoutIfNeeded()
        for (list, was) in zip(lists, before) {
            #expect(list.contentInset.bottom == was.0 && list.contentOffset.y == was.1, "a plain tap moved a tab")
        }
        controller.followDetachedComposer(rise: 0)
    }

    /// A reply on Recent rides the detached composer: its end rises over the
    /// field, the panel's own layout passes keep the rise, Popular stays,
    /// and the keys gone, Recent is back at its end.
    @Test func aReplyOnRecentRidesTheDetachedComposer() async {
        let (controller, window) = await sheetPanel()
        defer {
            controller.composeBar.debugTextView.resignFirstResponder()
            window.isHidden = true
        }
        controller.showStream(.recent, animated: false)
        let recent = controller.recent.collectionView
        let popular = controller.popular.collectionView
        let inset = recent.contentInset.bottom
        let popularBefore = (popular.contentInset.bottom, popular.contentOffset.y)
        controller.composeBar.debugTextView.raisesNoKeyboard()
        controller.recent.enterReplyState(for: CommentDisplayModel(entry: comment(0)))

        controller.followDetachedComposer(rise: 300)
        controller.view.setNeedsLayout()
        controller.view.layoutIfNeeded()
        #expect(abs(recent.contentInset.bottom - (inset + 300)) < 0.5, "Recent did not ride the reply's keys")
        #expect(abs(recent.contentOffset.y - Self.tailOffset(recent)) < 1, "Recent's end went under the keys")
        #expect(popular.contentInset.bottom == popularBefore.0 && popular.contentOffset.y == popularBefore.1)

        controller.followDetachedComposer(rise: 0)
        #expect(abs(recent.contentInset.bottom - inset) < 0.5)
        #expect(abs(recent.contentOffset.y - Self.tailOffset(recent)) < 1)
    }

    /// A reply to a comment high up: the rows rise with the keys until its
    /// top meets the room's, never further — it stays in view — and the
    /// keys gone, a reader's Recent is back where it stood.
    @Test func aReplyHighUpKeepsTheCommentInView() async throws {
        let (controller, window) = await sheetPanel()
        defer {
            controller.composeBar.debugTextView.resignFirstResponder()
            window.isHidden = true
        }
        controller.showStream(.recent, animated: false)
        let recent = controller.recent.collectionView
        controller.debugScroll(to: Self.tailOffset(recent) - 300, userScroll: true)
        let before = recent.contentOffset.y
        recent.layoutIfNeeded()
        // The first comment a little under the room's top: high up.
        let highUp = recent.indexPathsForVisibleItems.sorted().compactMap { path -> String? in
            guard case .comment(let id) = controller.recent.streamDataSource.itemIdentifier(for: path),
                  let frame = recent.layoutAttributesForItem(at: path)?.frame,
                  frame.minY > before + recent.adjustedContentInset.top + 40 else { return nil }
            return id
        }
        let id = try #require(highUp.first)
        let frame = try #require(Self.frame(of: id, in: controller.recent))
        controller.composeBar.debugTextView.raisesNoKeyboard()
        controller.recent.enterReplyState(for: CommentDisplayModel(entry: comment(Int(id.dropFirst()) ?? 0)))

        controller.followDetachedComposer(rise: 300)
        let roomTop = recent.contentOffset.y + recent.adjustedContentInset.top
        #expect(recent.contentOffset.y > before + 0.5, "the rows did not rise")
        #expect(frame.minY >= roomTop - 0.5, "the answered comment went under the bar")
        #expect(recent.contentOffset.y < before + 300, "the rise was not capped")

        controller.followDetachedComposer(rise: 0)
        #expect(abs(recent.contentOffset.y - before) < 0.5, "Recent did not go back where it stood")
    }

    /// A reply on Popular rides the detached composer, armed through a
    /// layout pass before the keys: the comment answered ends over the
    /// field, and the keys gone, Popular is back at its top.
    @Test func aReplyOnPopularRidesTheDetachedComposerToItsRow() async throws {
        let (controller, window) = await sheetPanel()
        defer {
            controller.composeBar.debugTextView.resignFirstResponder()
            window.isHidden = true
        }
        let stream = controller.popular
        let id = try #require(Self.firstRowUnderTheComposer(stream))
        reply(controller, to: try #require(Int(id.dropFirst())))
        controller.followDetachedComposer(rise: 0)

        controller.followDetachedComposer(rise: 300)
        let row = try #require(Self.frame(of: id, in: stream))
        #expect(row.maxY <= Self.visibleBottom(stream.collectionView) + 0.5, "the answered comment is under the keys")

        controller.followDetachedComposer(rise: 0)
        #expect(abs(stream.collectionView.contentOffset.y - Self.topOffset(stream.collectionView)) < 0.5)
    }

    // MARK: - The tabs' ends (#2008)

    private static let rightward = CGPoint(x: 820, y: 0)
    private static let leftward = CGPoint(x: -820, y: 0)

    /// Whether the tabs' pager would take a drag beginning mid-stream.
    private static func takes(_ controller: PostDetailViewController, velocity: CGPoint) -> Bool {
        let pager = controller.streamPager
        guard let scroll = pager.pagingScrollView as? HorizontalPagerScrollView else { return true }
        pager.layoutIfNeeded()
        let point = CGPoint(x: scroll.contentOffset.x + pager.bounds.width / 2, y: pager.bounds.height / 2)
        return scroll.isScrollEnabled && !scroll.shouldYield(at: point, velocity: velocity)
    }

    /// ⚠️ PAST EITHER END, THE SCREEN'S (#2008): on Popular, the first tab, a
    /// rightward drag is the page's — the grab of a pushed post, Shots back to
    /// Feed; on Recent, the last, a leftward one is — the side list. Between
    /// the tabs the pager keeps both. Decided as the pager's pan begins, with
    /// no recognizer of its own: the screen's own gestures receive the drag.
    @Test func pastEitherEndTheDragIsTheScreens() async {
        let (controller, window) = panel(PagedComments(count: 30, pageSize: 30))
        defer { window.isHidden = true }
        #expect(await settle { Self.loaded(controller.popular) })
        #expect(controller.visibleStreamKind == .popular)
        #expect(!Self.takes(controller, velocity: Self.rightward), "the pager kept the drag past Popular")
        #expect(Self.takes(controller, velocity: Self.leftward), "the pager gave away the drag to Recent")

        controller.showStream(.recent, animated: false)
        #expect(!Self.takes(controller, velocity: Self.leftward), "the pager kept the drag past Recent")
        #expect(Self.takes(controller, velocity: Self.rightward), "the pager gave away the drag to Popular")
    }

    /// A short thread's tabs take the swipe too (#2287): leftward from
    /// Popular to Recent; past Popular's end the drag stays the screen's.
    @Test func aShortThreadsTabsTakeTheSwipe() async {
        let (controller, window) = panel(PagedComments(count: 5, pageSize: 20))
        defer { window.isHidden = true }
        #expect(await settle { Self.loaded(controller.recent) })
        #expect(Self.takes(controller, velocity: Self.leftward), "the swipe to Recent went to the screen")
        #expect(!Self.takes(controller, velocity: Self.rightward), "the pager kept a drag past Popular")
    }
}
