import CoreModels
import MediaCore
import MediaPlayback
import Testing
import UIKit
@testable import Feed

/// **The specification for what the full-screen pager shows.**
///
/// ## Why this is written as a specification
///
/// This area has now been fixed six times by patching whichever symptom was
/// reported, and each fix produced the next defect: a page arriving black, a
/// page emptying on the way out, a page unreachable, a pager locked on the
/// wrong post, a scroll that jumped mid-gesture. Every one of them was a
/// disagreement between some bookkeeping and the pixels, and every test written
/// alongside a fix pinned the bookkeeping — so the suite stayed green while the
/// screen was wrong.
///
/// So this suite is written first and against the PIXELS only. It asks two
/// questions a viewer could answer by looking:
///
/// * which posts are showing their comments panel (`debugPostsShowingComments`,
///   read off the cells);
/// * whether the pager can be scrolled.
///
/// It names no slot, no warm, no preview, no promotion, no ceiling. Any
/// implementation that satisfies it is acceptable — including a much simpler
/// one than the machinery these rules currently sit on, which is the point.
///
/// ⚠️ A failing case here is a statement about the product, not about a
/// mechanism. Change the mechanism freely; change these only with a reason a
/// viewer would recognise.
@MainActor
struct SnapPageDisplaySpecTests {
    // MARK: - Fixtures

    private func model(_ id: String, media: URL?) -> FeedItemDisplayModel {
        FeedItemDisplayModel(
            id: PostID(id), authorID: ProfileID("a"), authorName: "A", metaText: "",
            avatarURL: nil, caption: "caption", mediaURL: media, mediaKind: .image,
            thumbnailURL: nil, audioText: nil, likeCount: 0
        )
    }

    private func media(_ id: String) -> FeedItemDisplayModel {
        model(id, media: URL(string: "https://example.test/\(id).jpg"))
    }

    private func text(_ id: String) -> FeedItemDisplayModel { model(id, media: nil) }

    @MainActor
    private final class Panels {
        private(set) var byPost: [PostID: Int] = [:]
        func make(_ id: PostID) -> UIViewController {
            byPost[id, default: 0] += 1
            let controller = UIViewController()
            controller.view.backgroundColor = .white
            return controller
        }
        func count(_ id: String) -> Int { byPost[PostID(id)] ?? 0 }
    }

    private func feed(
        _ models: [FeedItemDisplayModel], panels: Panels
    ) -> SnapFeedViewController {
        let controller = SnapFeedViewController(
            viewModel: FeedViewModel(repository: SilentProvider()),
            imagePipeline: ImagePipeline(fetcher: PlaceholderImageFetcher()),
            makeCommentsPanelContent: { id in panels.make(id) }
        )
        controller.loadViewIfNeeded()
        controller.view.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        controller.seedProjection(models)
        controller.view.layoutIfNeeded()
        controller.beginAppearanceTransition(true, animated: false)
        controller.endAppearanceTransition()
        return controller
    }

    private func collection(_ feed: SnapFeedViewController) -> UICollectionView? {
        feed.view.subviews.compactMap { $0 as? UICollectionView }.first
    }

    /// Scrolls to an arbitrary fraction of a page and lets the screen react the
    /// way it does mid-gesture — cells realize, `willDisplay` fires, nothing
    /// settles. This is where four of the six defects lived.
    private func scroll(_ feed: SnapFeedViewController, toPageFraction fraction: CGFloat) {
        guard let collection = collection(feed) else { return }
        collection.contentOffset.y = collection.bounds.height * fraction
        collection.layoutIfNeeded()
        feed.debugRealizeVisibleCells()
    }

    /// And a completed page change: scrolled, released, settled.
    private func settle(_ feed: SnapFeedViewController, onPage index: Int) {
        guard let collection = collection(feed) else { return }
        scroll(feed, toPageFraction: CGFloat(index))
        feed.scrollViewDidEndDecelerating(collection)
    }

    // MARK: - What a text page shows

    /// A text post's caption and thread ARE its page: with no panel it is not
    /// an undecorated page, it is an empty one.
    @Test func aTextPageShowsItsPanelWhenItIsTheOnlyPage() {
        let panels = Panels()
        let feed = feed([text("a")], panels: panels)

        #expect(feed.debugPostsShowingComments == [PostID("a")])
    }

    /// ⚠️ AND AS SOON AS IT HAS PIXELS ON SCREEN — not when the scroll stops.
    ///
    /// Reported as a page arriving black and filling itself in a beat later.
    @Test func anArrivingTextPageShowsItsPanelBeforeItSettles() {
        let panels = Panels()
        let feed = feed([text("a"), text("b")], panels: panels)

        scroll(feed, toPageFraction: 0.5)

        #expect(feed.debugPostsShowingComments.contains(PostID("b")),
                "the arriving page was blank while it was half on screen")
    }

    /// ⚠️ AND THE PAGE BEING LEFT KEEPS ITS OWN, for as long as it has pixels.
    ///
    /// Reported as the outgoing page going black at the release, with its
    /// composer bar left hanging over nothing.
    @Test func aDepartingTextPageKeepsItsPanelWhileItIsStillVisible() {
        let panels = Panels()
        let feed = feed([text("a"), text("b")], panels: panels)

        scroll(feed, toPageFraction: 0.5)

        #expect(feed.debugPostsShowingComments.contains(PostID("a")),
                "the page being left was emptied while it was still on screen")
    }

    /// Both at once is the whole of the mid-scroll state, and it is worth
    /// asserting as one thing: a viewer looking at the screen sees two pages,
    /// and both of them are pages.
    @Test func bothPagesAreThemselvesMidScroll() {
        let panels = Panels()
        let feed = feed([text("a"), text("b")], panels: panels)

        scroll(feed, toPageFraction: 0.5)

        #expect(feed.debugPostsShowingComments == [PostID("a"), PostID("b")])
    }

    /// A media page shows no comments panel by simply arriving — its thread is
    /// a second surface, opened by pressing the count.
    @Test func aMediaPageShowsNoPanelOfItsOwn() {
        let panels = Panels()
        let feed = feed([media("a"), text("b")], panels: panels)

        #expect(feed.debugPostsShowingComments.isEmpty)
    }

    /// Nothing keeps a panel once it is off screen — the memory belongs to the
    /// pages a viewer can see.
    @Test func aPageThatHasLeftShowsNothing() {
        let panels = Panels()
        let feed = feed([text("a"), text("b"), text("c")], panels: panels)

        settle(feed, onPage: 2)

        #expect(feed.debugPostsShowingComments.contains(PostID("a")) == false)
    }

    /// One panel per post per visit. Two is a page built twice, which is the
    /// cost the warming exists to avoid.
    @Test func aPostCostsOnePanel() {
        let panels = Panels()
        let feed = feed([text("a"), text("b")], panels: panels)

        scroll(feed, toPageFraction: 0.5)
        settle(feed, onPage: 1)

        #expect(panels.count("a") == 1)
        #expect(panels.count("b") == 1)
    }

    // MARK: - What the pager allows

    /// A text page owns the vertical axis — its thread scrolls — so the pager
    /// itself is locked and the page swipe is the way out.
    @Test func aTextPageLocksThePager() {
        let panels = Panels()
        let feed = feed([text("a"), media("b")], panels: panels)

        #expect(feed.debugPagerIsLocked)
    }

    /// ⚠️ AND A MEDIA PAGE ALWAYS GIVES IT BACK.
    ///
    /// Reported as a feed that could not be scrolled at all: the lock had been
    /// left behind by a text post two pages earlier.
    @Test func aMediaPageAlwaysGivesThePagerBack() {
        let panels = Panels()
        let feed = feed([text("a"), media("b"), media("c")], panels: panels)

        settle(feed, onPage: 1)

        #expect(feed.debugPagerIsLocked == false)
    }

    /// Every page is reachable, whatever the feed is made of. A page the pager
    /// refuses to advance onto draws nothing wrong and logs nothing — the
    /// gesture simply stops working.
    @Test(arguments: [
        ["text", "text", "text"],
        ["text", "media", "text"],
        ["media", "text", "text"],
        ["text", "text", "media"],
    ])
    func everyPageIsReachable(shape: [String]) {
        let panels = Panels()
        let models = shape.enumerated().map { index, kind in
            kind == "text" ? text("p\(index)") : media("p\(index)")
        }
        let feed = feed(models, panels: panels)

        for index in 0..<(shape.count - 1) {
            #expect(feed.debugReachableCeiling() > index,
                    Comment(rawValue: "the pager refused to leave page \(index) of \(shape)"))
            settle(feed, onPage: index + 1)
        }

        #expect(feed.activePostID == PostID("p\(shape.count - 1)"))
    }

    /// ⚠️ THE SCROLL IS THE VIEWER'S. Nothing may move it mid-gesture.
    ///
    /// Reported after an attempt to start videos earlier: activating the page
    /// at the halfway mark ran the settle's whole choreography, which brings
    /// the active page clear of the chrome — so the feed jumped to the next
    /// page under the finger.
    @Test func nothingMovesTheScrollWhileTheViewerIsDragging() {
        let panels = Panels()
        let feed = feed([text("a"), media("b"), text("c")], panels: panels)
        guard let collection = collection(feed) else { return }

        for fraction in [0.25, 0.5, 0.75, 1.25, 1.5] {
            let asked = collection.bounds.height * fraction
            scroll(feed, toPageFraction: fraction)
            #expect(abs(collection.contentOffset.y - asked) < 0.5,
                    Comment(rawValue: "the screen moved the scroll at \(fraction) of a page"))
        }
    }
}

/// Vends nothing: this suite is about what the screen does with what it has.
private final class SilentProvider: FeedProviding, @unchecked Sendable {
    func cachedFirstPage() async -> [FeedEntry]? { nil }
    func loadFirstPage() async throws -> FeedPage {
        FeedPage(entries: [], nextPageToken: nil, isCold: false)
    }
    func loadPage(afterToken token: String) async throws -> FeedPage {
        FeedPage(entries: [], nextPageToken: nil, isCold: false)
    }
    func loadPost(_ id: PostID) async throws -> FeedEntry {
        FeedEntry(
            post: Post(
                id: id, authorID: ProfileID("p"), caption: "",
                attachments: [], publishedAt: Date(timeIntervalSince1970: 0)
            ),
            author: AuthorSummary(
                id: ProfileID("p"), handle: "ava", displayName: "Ava", avatarURL: nil
            ),
            likeCount: 0
        )
    }
}
