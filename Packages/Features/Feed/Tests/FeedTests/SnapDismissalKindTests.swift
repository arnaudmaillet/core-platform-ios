import CoreModels
import CoreNavigation
import MediaCore
import MediaPlayback
import Testing
import UIKit
@testable import Feed

/// What the post on screen travels as, asked of the screen that is showing it.
///
/// This is the ONE question the whole dismissal seam is built on: two grabs and
/// one delegate slot all decide what they do by asking it, so a wrong answer
/// here is not a wrong animation, it is no animation — either both drivers
/// stand down, or the one that claims the drag cannot animate what it claimed.
///
/// It has to be asked of the ACTIVE PAGE rather than of what the screen opened
/// with, because this screen is a pager: the viewer routinely closes a post
/// that is not the one they tapped.
@MainActor
struct SnapDismissalKindTests {
    private func model(_ id: String, media: URL?) -> FeedItemDisplayModel {
        FeedItemDisplayModel(
            id: PostID(id),
            authorID: ProfileID("a"),
            authorName: "A",
            metaText: "",
            avatarURL: nil,
            caption: "caption",
            mediaURL: media,
            mediaKind: .image,
            thumbnailURL: nil,
            audioText: nil,
            likeCount: 0
        )
    }

    private func media(_ id: String) -> FeedItemDisplayModel {
        model(id, media: URL(string: "https://example.test/\(id).jpg"))
    }

    private func text(_ id: String) -> FeedItemDisplayModel {
        model(id, media: nil)
    }

    /// Counts how many panels the feed actually BUILT.
    ///
    /// The point of warming a text page's interface is that the mount pays
    /// nothing, and "was it warmed" cannot show that on its own — a mount that
    /// ignored the warm and built a second one looks identical from the
    /// outside. The count is the half that tells them apart.
    ///
    /// Counted PER POST, because this screen warms panels on another path too
    /// (a media page's tap-to-comments): a total would move for reasons that
    /// have nothing to do with the page under test.
    @MainActor
    private final class PanelBuilds {
        private(set) var byPost: [PostID: Int] = [:]
        func make(_ id: PostID) -> UIViewController {
            byPost[id, default: 0] += 1
            return UIViewController()
        }
        func count(_ id: String) -> Int { byPost[PostID(id)] ?? 0 }
    }

    private func feed(
        _ models: [FeedItemDisplayModel], panels: PanelBuilds? = nil
    ) -> SnapFeedViewController {
        let controller = SnapFeedViewController(
            viewModel: FeedViewModel(repository: MuteFeedProvider()),
            imagePipeline: ImagePipeline(fetcher: PlaceholderImageFetcher()),
            makeCommentsPanelContent: panels.map { builds in { id in builds.make(id) } }
        )
        controller.loadViewIfNeeded()
        controller.view.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        controller.seedProjection(models)
        controller.view.layoutIfNeeded()
        // ⚠️ ON SCREEN, or the active page is `nil` whatever the offset says:
        // the dispatcher reports no active item while the surface is down, and
        // a test that skipped this would read every answer off page zero and
        // call the paging cases green for the wrong reason.
        controller.beginAppearanceTransition(true, animated: false)
        controller.endAppearanceTransition()
        return controller
    }

    /// Pages the feed the way a settled swipe does: move the offset, then tell
    /// the screen the scroll came to rest. The active page is recomputed there
    /// and nowhere else, so a test that only moved the offset would be asking
    /// about the page the viewer left.
    private func page(_ feed: SnapFeedViewController, to index: Int) {
        guard let collection = feed.view.subviews
            .compactMap({ $0 as? UICollectionView }).first else { return }
        collection.setContentOffset(
            CGPoint(x: 0, y: collection.bounds.height * CGFloat(index)), animated: false
        )
        feed.scrollViewDidEndDecelerating(collection)
    }

    /// A post with media has something for a hero to carry.
    @Test func aPostWithMediaFlies() {
        #expect(feed([media("m")]).zoomDismissalKind == .hero)
    }

    /// ⚠️ AND A TEXT POST TRAVELS AS A CARD — it has no media, so there is
    /// nothing a flight could carry between the two screens.
    @Test func aPostWithNoMediaTravelsAsACard() {
        #expect(feed([text("t")]).zoomDismissalKind == .card)
    }

    /// ⚠️ THE ANSWER FOLLOWS THE PAGE, NOT THE OPENING.
    ///
    /// The defect this pins is the reported one: open a media post, scroll down
    /// onto a text post, and close. Answering from the opening tap sends a hero
    /// after media that is not on screen.
    @Test func pagingOntoATextPostChangesTheAnswer() {
        let feed = feed([media("m"), text("t")])
        #expect(feed.zoomDismissalKind == .hero)

        page(feed, to: 1)

        #expect(feed.zoomDismissalKind == .card)
    }

    /// And the mirror, which is the same bug from the other side: opening a
    /// text post as a window and paging onto media must give the hero back.
    @Test func pagingOntoAMediaPostGivesTheFlightBack() {
        let feed = feed([text("t"), media("m")])
        #expect(feed.zoomDismissalKind == .card)

        page(feed, to: 1)

        #expect(feed.zoomDismissalKind == .hero)
    }

    /// ⚠️ AN UNANSWERABLE SCREEN SAYS `.hero`, WHICH IS WHAT EVERY CALLER MEANT
    /// BEFORE THE QUESTION EXISTED.
    ///
    /// A feed with nothing loaded yet is asked this on any pop that beats its
    /// first page in — and the fallback has to be the historical answer, or a
    /// perfectly ordinary flight is silently downgraded during the window where
    /// the screen knows least.
    @Test func aFeedWithNothingToShowFallsBackToFlying() {
        #expect(feed([]).zoomDismissalKind == .hero)
    }

    /// ⚠️ AND IT SURVIVES THE SCREEN GOING AWAY, which is the only moment it
    /// is ever asked.
    ///
    /// The page index used to come from the ACTIVE item, and "active" means
    /// visible — a screen that is being popped reports its surface down before
    /// the pop asks anything, so every question fell back to page ZERO: the
    /// post the viewer opened with, not the one they are closing.
    ///
    /// Measured on a back-button close from page 11 of a text post: the pop was
    /// told `.hero` because post zero is a photograph, and the close that had
    /// already adopted and concealed the landed row was handed to a driver that
    /// could not land on it. The feed came back with a hole in it.
    @Test func theAnswerSurvivesTheScreenBeingDismissed() {
        let feed = feed([media("m"), text("t")])
        page(feed, to: 1)
        #expect(feed.zoomDismissalKind == .card)

        // What a pop does first.
        feed.beginAppearanceTransition(false, animated: false)
        feed.endAppearanceTransition()

        #expect(feed.zoomDismissalKind == .card, "the closing screen forgot which post it was on")
        #expect(feed.activePostID == PostID("t"))
    }

    /// The settle is what arms the warm, not UIKit's scroll heuristic.
    ///
    /// `UICollectionViewDataSourcePrefetching` warms nothing while the pager is
    /// at rest, and during a fling only what its velocity heuristic reached. A
    /// feed whose promise is that the next page is instant cannot be built on
    /// that: after every settle the window is stated outright, so the pages
    /// either side are ready whether the viewer arrived by flick, by tap, or by
    /// sitting still for a minute first.
    @Test func settlingOnAPageWarmsTheWindowAroundIt() {
        let feed = feed([media("a"), media("b"), media("c"), media("d"), media("e")])

        page(feed, to: 2)

        // Two ahead, one behind, nearest first — see `SnapWarmWindow`.
        #expect(feed.debugLastWarmedWindow == [3, 1, 4])
    }

    /// And it clamps at the end of the feed rather than asking for pages that
    /// are not there.
    @Test func theWarmStopsAtTheEndOfTheFeed() {
        let feed = feed([media("a"), media("b"), media("c")])

        page(feed, to: 2)

        #expect(feed.debugLastWarmedWindow == [1])
    }

    /// ⚠️ A TEXT PAGE'S INTERFACE IS BUILT BEFORE ITS CELL EXISTS.
    ///
    /// A text page IS its comments panel — a whole view controller, roughly
    /// 100ms of layout — and it was constructed at `willDisplay`, which is the
    /// same moment the empty page is on screen. Reported from a recording: the
    /// next page arrives as a black rectangle and fills itself in a beat later.
    /// Warming the data was not enough, because the cost was never the data.
    @Test func theNextTextPagesInterfaceIsBuiltAhead() {
        let panels = PanelBuilds()
        let feed = feed([media("a"), text("b"), media("c")], panels: panels)

        page(feed, to: 0)

        #expect(feed.debugPrewarmedRestingID == PostID("b"))
        #expect(panels.count("b") == 1, "the page ahead was not built")
    }

    /// ⚠️ AND THE MOUNT SPENDS IT RATHER THAN BUILDING A SECOND ONE.
    ///
    /// Without this half the warm is pure cost: a panel built ahead, ignored,
    /// and built again at exactly the moment it was meant to save.
    @Test func theMountSpendsTheWarmRatherThanBuildingAgain() {
        let panels = PanelBuilds()
        let feed = feed([media("a"), text("b"), media("c")], panels: panels)
        page(feed, to: 0)
        #expect(panels.count("b") == 1)

        page(feed, to: 1)

        #expect(panels.count("b") == 1, "the mount built a second panel over the warm one")
        #expect(feed.debugPrewarmedRestingID == PostID("b"), "the warm was never claimed")
    }

    /// A media page ahead is warmed by its cover, not by a panel — building one
    /// for it would be a view controller nobody mounts.
    @Test func aMediaPageAheadGetsNoPanel() {
        let panels = PanelBuilds()
        let feed = feed([media("a"), media("b"), media("c")], panels: panels)

        page(feed, to: 0)

        #expect(panels.count("b") == 0, "a media page ahead was given a panel")
        #expect(feed.debugPrewarmedRestingID == nil)
    }

    /// The answer is a pure question — asking it must not activate a page,
    /// start a player, or otherwise move the screen. Both grabs ask it on every
    /// touch that reaches them.
    @Test func askingChangesNothing() {
        let feed = feed([media("m"), text("t")])
        page(feed, to: 1)
        let active = feed.activePostID

        for _ in 0..<5 { _ = feed.zoomDismissalKind }

        #expect(feed.activePostID == active)
        #expect(feed.zoomDismissalKind == .card)
    }
}

/// Vends nothing: these are about the question the feed answers, not about what
/// it loads through the repository.
private final class MuteFeedProvider: FeedProviding, @unchecked Sendable {
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
