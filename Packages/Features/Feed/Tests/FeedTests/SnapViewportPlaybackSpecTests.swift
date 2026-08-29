import CoreModels
import MediaCore
import MediaPlayback
import Testing
import UIKit
@testable import Feed

/// **THE SPECIFICATION FOR WHEN A CLIP PLAYS: the page that owns the screen
/// plays, and the settle has nothing to do with it.**
///
/// ## Why this is a specification and not a patch
///
/// This was built once and taken out again, and the reason it came out is the
/// whole difficulty: the first attempt started the clip by ACTIVATING the page
/// at the halfway mark, and activation is a choreography — it warms a window,
/// re-points the chrome, reconciles the resting interface and brings the
/// active page clear of the toolbar. Run mid-drag, that last part moved the
/// scroll under the finger. The feed jumped a page, and the fix was reverted
/// wholesale rather than separated.
///
/// So the rule is stated here as two independent facts a viewer could check by
/// looking, and the second one is the one that was violated:
///
/// * the clip on the page covering most of the screen is running;
/// * NOTHING else about the screen reacts to that — not the scroll, not the
///   settled page, not the interface, not the pager's lock.
///
/// ⚠️ WHAT THIS CANNOT SEE. A unit test has no decoder: it can prove the page
/// was told to play and that nothing else moved, not that pixels advanced.
/// The picture is verified in the simulator against `-media-log`'s
/// `[page-play]` line, which prints the surface and whether a player was
/// already hosted.
@MainActor
struct SnapViewportPlaybackSpecTests {
    // MARK: - Fixtures

    private static func model(_ id: String, kind: MediaKind, media: URL?) -> FeedItemDisplayModel {
        FeedItemDisplayModel(
            id: PostID(id), authorID: ProfileID("a"), authorName: "A", metaText: "",
            avatarURL: nil, caption: "caption", mediaURL: media, mediaKind: kind,
            thumbnailURL: nil, audioText: nil, likeCount: 0
        )
    }

    private static func video(_ id: String) -> FeedItemDisplayModel {
        model(id, kind: .video, media: URL(string: "https://example.test/\(id).mp4"))
    }

    private static func photo(_ id: String) -> FeedItemDisplayModel {
        model(id, kind: .image, media: URL(string: "https://example.test/\(id).jpg"))
    }

    private static func text(_ id: String) -> FeedItemDisplayModel {
        model(id, kind: .image, media: nil)
    }

    /// A feed being dragged, with the ONE piece of stagecraft these cases turn
    /// on: a cell is announced to the delegate the first time it appears, and
    /// never again.
    ///
    /// ⚠️ This is not a detail. `willDisplay` recomputes the active page, and
    /// re-announcing every visible cell on every frame — which is what the
    /// blunt debug helper does — therefore re-activates mid-drag and produces a
    /// page change UIKit would never have produced. Three cases below "failed"
    /// against that artifact before the harness was made honest, and each of
    /// them would have been read as a defect in the screen.
    @MainActor
    private final class Stage {
        let feed: SnapFeedViewController
        let pager: UICollectionView
        private var announced: Set<Int> = []
        /// Where the drag currently is, in pages.
        private var current: CGFloat = 0

        init(_ models: [FeedItemDisplayModel]) {
            feed = SnapFeedViewController(
                viewModel: FeedViewModel(repository: MuteProvider()),
                imagePipeline: ImagePipeline(fetcher: PlaceholderImageFetcher()),
                makeCommentsPanelContent: { _ in UIViewController() }
            )
            feed.loadViewIfNeeded()
            feed.view.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
            feed.seedProjection(models)
            feed.view.layoutIfNeeded()
            feed.beginAppearanceTransition(true, animated: false)
            feed.endAppearanceTransition()
            pager = feed.view.subviews.compactMap { $0 as? UICollectionView }.first!
            announceNewCells()
        }

        /// Mid-gesture: the offset moves, cells that have just come into view
        /// are announced, and NOTHING settles.
        ///
        /// ⚠️ CONTINUOUSLY, in small steps, because a finger is continuous and
        /// one of the facts under test depends on it. A cell is announced to
        /// the delegate when it first appears, and that announcement recomputes
        /// the active page from wherever the scroll happens to be — so a
        /// harness that teleports from 0 to 0.6 realizes the arriving cell
        /// PAST the midpoint and activates it, which no real drag does. Three
        /// cases below failed against exactly that artifact.
        func drag(to fraction: CGFloat) {
            let step: CGFloat = 0.05
            while abs(current - fraction) > 0.001 {
                current += (fraction > current ? min(step, fraction - current)
                                               : -min(step, current - fraction))
                pager.contentOffset.y = pager.bounds.height * current
                pager.layoutIfNeeded()
                announceNewCells()
                feed.scrollViewDidScroll(pager)
            }
        }

        /// Released, snapped home, settled.
        func settle(on index: Int) {
            drag(to: CGFloat(index))
            feed.scrollViewDidEndDecelerating(pager)
        }

        private func announceNewCells() {
            for path in pager.indexPathsForVisibleItems.sorted() where !announced.contains(path.item) {
                guard let cell = pager.cellForItem(at: path) else { continue }
                announced.insert(path.item)
                feed.collectionView(pager, willDisplay: cell, forItemAt: path)
            }
        }
    }

    // MARK: - Who plays

    /// The page a viewer is looking at when they have not moved is playing.
    @Test func theOpeningPagePlays() {
        let stage = Stage([Self.video("a"), Self.video("b")])

        #expect(stage.feed.debugPlayingPostID == PostID("a"))
    }

    /// ⚠️ THE ARRIVING PAGE TAKES OVER AT THE HALFWAY MARK — the request.
    ///
    /// "Si le prochain post est un post de type media avec une vidéo, lancer
    /// la vidéo dès que le post dépasse la moitié de l'écran."
    @Test func theArrivingPagePlaysOncePastHalfTheScreen() {
        let stage = Stage([Self.video("a"), Self.video("b")])

        stage.drag(to: 0.6)

        #expect(stage.feed.debugPlayingPostID == PostID("b"),
                "the arriving clip is not playing though it owns the screen")
    }

    /// And not a moment before: below half, the page being left still owns the
    /// screen and keeps the picture.
    @Test func thePageBeingLeftKeepsPlayingUntilTheHalfway() {
        let stage = Stage([Self.video("a"), Self.video("b")])

        stage.drag(to: 0.4)

        #expect(stage.feed.debugPlayingPostID == PostID("a"))
    }

    /// Exactly at the mark the arriving page owns it — the boundary is stated
    /// rather than left to whichever way a rounding falls.
    @Test func theMarkItselfBelongsToTheArrivingPage() {
        let stage = Stage([Self.video("a"), Self.video("b")])

        stage.drag(to: 0.5)

        #expect(stage.feed.debugPlayingPostID == PostID("b"))
    }

    /// It follows the viewer BACK too: a drag that changes its mind hands the
    /// picture back to the page it came from.
    @Test func playbackFollowsTheViewerBack() {
        let stage = Stage([Self.video("a"), Self.video("b")])

        stage.drag(to: 0.7)
        stage.drag(to: 0.2)

        #expect(stage.feed.debugPlayingPostID == PostID("a"))
    }

    /// The settle changes nothing about WHO plays — it only agrees. A page
    /// that started at the halfway mark must not be restarted when the scroll
    /// stops, which is what a second, independent start would be.
    @Test func theSettleAgreesWithWhatIsAlreadyPlaying() {
        let stage = Stage([Self.video("a"), Self.video("b")])

        stage.drag(to: 0.6)
        stage.settle(on: 1)

        #expect(stage.feed.debugPlayingPostID == PostID("b"))
    }

    /// A page with nothing to play owns the screen all the same — and the clip
    /// it displaced stops. Otherwise a video keeps running under a photograph,
    /// which is the defect the carousel's autoplay already fixed one level
    /// down.
    @Test func aPageWithNoClipStillTakesTheScreenFromOne() {
        let stage = Stage([Self.video("a"), Self.photo("b")])

        stage.drag(to: 0.6)

        #expect(stage.feed.debugPlayingPostID == nil,
                "a clip kept playing while a photograph owned the screen")
    }

    /// Same for a text page, which is the other half of the corpus.
    @Test func aTextPageTakesTheScreenFromAClipToo() {
        let stage = Stage([Self.video("a"), Self.text("b")])

        stage.drag(to: 0.6)

        #expect(stage.feed.debugPlayingPostID == nil)
    }

    // MARK: - And nothing else moves

    /// ⚠️ THE SCROLL IS THE VIEWER'S. This is the regression that took the
    /// first attempt out: activating at the halfway mark ran the settle's
    /// choreography, which brings the active page clear of the chrome — so the
    /// feed jumped under the finger.
    @Test func startingAClipDoesNotMoveTheScroll() {
        let stage = Stage([Self.video("a"), Self.video("b"), Self.video("c")])

        for fraction in [0.3, 0.5, 0.6, 0.9, 1.4, 1.6] {
            let asked = stage.pager.bounds.height * fraction
            stage.drag(to: fraction)
            #expect(abs(stage.pager.contentOffset.y - asked) < 0.5,
                    Comment(rawValue: "the screen moved the scroll at \(fraction) of a page"))
        }
    }

    /// The SETTLED page is still the one the viewer released on. Playback
    /// crossing the halfway mark is not a page change: the chrome, the toolbar
    /// and everything else keyed to the active page must not follow it
    /// mid-drag.
    @Test func startingAClipDoesNotChangeTheSettledPage() {
        let stage = Stage([Self.video("a"), Self.video("b")])

        stage.drag(to: 0.6)

        #expect(stage.feed.activePostID == PostID("a"),
                "the page changed mid-drag: the settle's choreography ran")
    }

    /// And NO INTERFACE IS TAKEN AWAY. The page being left keeps its panel for
    /// as long as it has pixels — that is the rule `SnapPageDisplaySpecTests`
    /// owns, and the picture changing hands at the midpoint must not be a
    /// second, quieter way of breaking it.
    ///
    /// A superset, not an equality: the ARRIVING page mounts its own panel on
    /// the way in (the pre-render doctrine — a text page must never arrive
    /// blank), so the set grows during a drag. What it may never do is shrink.
    @Test func startingAClipTakesNoInterfaceAway() {
        let stage = Stage([Self.text("a"), Self.text("b")])
        let before = stage.feed.debugPostsShowingComments

        stage.drag(to: 0.6)

        #expect(before.isSubset(of: stage.feed.debugPostsShowingComments),
                "a page lost its panel when the picture changed hands")
    }

    /// Nor does it touch the pager's lock, which belongs to the settled page.
    @Test func startingAClipLeavesThePagerLockAlone() {
        let stage = Stage([Self.text("a"), Self.video("b")])
        let before = stage.feed.debugPagerIsLocked

        stage.drag(to: 0.6)

        #expect(stage.feed.debugPagerIsLocked == before)
    }
}

/// Vends nothing: these are about what the screen does with what it has.
private final class MuteProvider: FeedProviding, @unchecked Sendable {
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
