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
    private(set) var recentPagesAsked = 0

    init(count: Int, pageSize: Int) {
        all = (0..<count).map { comment($0) }
        self.pageSize = pageSize
    }

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

    /// Below `CommentSortPolicy`'s threshold: one Recent stream, no Popular
    /// tab — nothing mounted, nothing to swipe to.
    @Test func belowTheThresholdThereIsOneStream() async {
        let (controller, window) = panel(PagedComments(count: 5, pageSize: 20))
        defer { window.isHidden = true }
        #expect(await settle { Self.loaded(controller.recent) })
        #expect(!controller.showsPopular)
        #expect(controller.visibleStreamKind == .recent)
        #expect(!controller.streamPager.isPagingEnabled, "a single stream pages")
        #expect(controller.popular.collectionView.superview == nil, "Popular is mounted with no tab")
    }

    /// At the threshold, the first answer opens the panel on Popular.
    @Test func atTheThresholdThePanelOpensOnPopular() async {
        let (controller, window) = panel(PagedComments(count: CommentSortPolicy.minimumComments, pageSize: 20))
        defer { window.isHidden = true }
        #expect(await settle { Self.loaded(controller.popular) })
        #expect(controller.showsPopular)
        #expect(controller.visibleStreamKind == .popular)
        #expect(controller.streamPager.isPagingEnabled)
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
}
