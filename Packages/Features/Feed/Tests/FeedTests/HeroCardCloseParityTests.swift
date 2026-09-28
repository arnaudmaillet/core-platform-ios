import CoreModels
import CoreNavigation
import FeedInterface
import MediaCore
import PostGrid
import Testing
import UIKit
@testable import Feed

/// A post opened from a LIST with a flight, then closed from a TEXT page.
///
/// ## The defect
///
/// On a profile's Activity tab: tap a video post (a hero flies), page to the
/// next post, which is text, close. The profile came back on a CUT. The same
/// route from For You's Following list closed as a window onto the card.
///
/// The feed is a pager and the presentation was chosen at the tap: the flight
/// has no media to carry once the page is text, so both zoom grabs and the
/// flight's own pop animator refuse the `.card` close. For You arms a
/// card-shaped close beside every flight for exactly this; `presentSnapFeedHero`
/// armed one only when the presenter was the place page — so a profile got no
/// drag at all on that page, and a chevron that fell through to UIKit's pop.
///
/// These pin the choice of landing (pure) and that the seam arms the close for
/// any presenter that described its row.
@MainActor
struct HeroCardCloseParityTests {

    // MARK: - Which landing a text-page close picks

    /// A presenter that described its ROW lands on it — the profile's case, and
    /// the one that used to answer nil.
    @Test func aPresenterThatDescribedItsRowLandsOnIt() {
        let box = Box()
        let landing = FeedFeatureBuilder.cardCloseLanding(
            for: UIViewController(), origin: origin(reveal: reveal(box)),
            pipeline: nil, dock: { $0 }
        )
        #expect(landing is RowCardCloseLanding)
    }

    /// A presenter that cannot describe a row gets no window — what it had.
    @Test func aPresenterWithNoRowGetsNoCardClose() {
        let landing = FeedFeatureBuilder.cardCloseLanding(
            for: UIViewController(), origin: origin(reveal: nil),
            pipeline: nil, dock: { $0 }
        )
        #expect(landing == nil)
    }

    /// A presenter that IS a landing keeps its own answer, whatever its origin
    /// says — the place page stages tabs and tiles no origin describes.
    @Test func aScreenThatIsALandingKeepsItsOwnAnswer() {
        let screen = LandingScreen()
        let landing = FeedFeatureBuilder.cardCloseLanding(
            for: screen, origin: origin(reveal: reveal(Box())),
            pipeline: nil, dock: { $0 }
        )
        #expect(landing === screen)
    }

    /// The host's dock choreography is composed around the row, not dropped:
    /// the close restores the bar and must put it back down on a cancel.
    @Test func theDockChoreographyIsComposedAroundTheRow() {
        let box = Box()
        let landing = FeedFeatureBuilder.cardCloseLanding(
            for: UIViewController(), origin: origin(reveal: reveal(box)),
            pipeline: nil,
            dock: { row in
                row.replacingChrome(
                    presentationDidEnd: row.presentationDidEnd,
                    dismissalDidEnd: { committed in
                        box.events.append("dock")
                        row.dismissalDidEnd(committed)
                    }
                )
            }
        ) as? RowCardCloseLanding
        landing?.origin.dismissalDidEnd(false)
        #expect(box.events == ["dock", "row-dismiss"])
    }

    // MARK: - What the row landing stages

    /// The window closes onto the ROW's rect, re-asked — not a centred square.
    @Test func theWindowClosesOntoTheRow() {
        let box = Box()
        let landing = RowCardCloseLanding(origin: reveal(box), pipeline: nil)
        let geometry = landing.cardCloseGeometry(dismissing: UIViewController())
        #expect(geometry?.sourceFrame(UIView()) == box.row)
        // A list row's close CARRIES the page into the row, like For You's.
        #expect(geometry?.pageFit == .covering)
    }

    /// A row that cannot be found stages nothing, so the driver picks its plain
    /// slide rather than a window closing onto the middle of the screen.
    @Test func aRowThatCannotBeFoundStagesNothing() {
        let box = Box()
        box.row = nil
        let landing = RowCardCloseLanding(origin: reveal(box), pipeline: nil)
        #expect(landing.cardCloseGeometry(dismissing: UIViewController()) == nil)
    }

    /// The backstop puts the row back whatever animated the close.
    @Test func theBackstopUnconcealsTheRow() {
        let box = Box()
        RowCardCloseLanding(origin: reveal(box), pipeline: nil).clearLandingConcealment()
        #expect(box.concealed == [false])
    }

    // MARK: - The seam arms it

    /// ⚠️ THE DEFECT. A flight from a presenter that described its row must
    /// leave a card close installed beside it, holding the stack's delegate
    /// slot — the flight is what it forwards a `.hero` pop back to.
    @Test func aFlightFromARowArmsTheCardCloseBesideIt() {
        let stack = Stack()
        stack.builder.presentSnapFeedHero(
            postIDs: [PostID("m1")], from: stack.presenter,
            origin: origin(reveal: reveal(Box()))
        )

        let close = stack.nav.delegate as? InteractiveSlideDismissal
        #expect(close != nil, "a flight from a list row left no card close beside it")
        #expect(close?.arbitratesWithHeroGrab == true)
        #expect(close?.prepareForDismissal != nil)
        #expect(close?.onWillBeginPop != nil,
                "the close would land the row on a screen with no dock")
    }

    // MARK: - The dock comes back at the landing, never with the return

    /// A row close puts the dock's STATE back at its begin — outside any
    /// transition, so the landing's layout is final — but INVISIBLE: the
    /// product rule is that the bar appears at the landing, never with the
    /// return. The close used to fade it in 1:1 with the drag.
    @Test func aRowCloseRestoresTheDockOffstageAtItsBegin() {
        let stack = Stack()
        stack.builder.presentSnapFeedHero(
            postIDs: [PostID("m1")], from: stack.presenter,
            origin: origin(reveal: reveal(Box()))
        )
        #expect(stack.tabs.isTabBarHidden, "precondition: the push hides the dock")

        (stack.nav.delegate as? InteractiveSlideDismissal)?.onWillBeginPop?(.vertical)

        #expect(stack.tabs.isTabBarHidden == false, "the landing's layout would settle mid-flight")
        #expect(stack.tabs.tabBar.alpha == 0, "the dock would be seen during the return")
    }

    /// The chevron has no grab-begin; `onWillCloseFeed` is its equivalent, and
    /// it must do the same for EVERY kind of close — the flight's tap-back
    /// included, which used to reach the dock only inside the pop, where a bar
    /// un-hidden reads shown and draws nothing.
    @Test func theChevronRestoresTheDockOffstageToo() {
        let stack = Stack()
        stack.builder.presentSnapFeedHero(
            postIDs: [PostID("m1")], from: stack.presenter, origin: origin(reveal: nil)
        )
        let feed = stack.nav.viewControllers.last as? SnapFeedViewController
        #expect(feed?.onWillCloseFeed != nil, "a chevron close would restore the dock inside the pop")

        feed?.onWillCloseFeed?()

        #expect(stack.tabs.isTabBarHidden == false)
        #expect(stack.tabs.tabBar.alpha == 0)
    }

    /// The control: no row, no card close — the flight still owns the stack.
    @Test func aFlightWithNoRowIsLeftToTheFlight() {
        let stack = Stack()
        stack.builder.presentSnapFeedHero(
            postIDs: [PostID("m1")], from: stack.presenter, origin: origin(reveal: nil)
        )
        #expect(stack.nav.delegate is ZoomTransitionController)
    }

    /// The other direction: a post opened as a WINDOW and paged onto a photo.
    /// No flight exists on this path, so a chevron's pop must not be forwarded
    /// to the displaced delegate (whose nil is UIKit's plain pop) — the same
    /// answer For You's list gives for a text row.
    @Test func aWindowOpenedPostNeverForwardsItsCloseToAHero() {
        let stack = Stack()
        stack.builder.presentSnapFeedHero(
            postIDs: [PostID("t1")], from: stack.presenter,
            origin: origin(reveal: reveal(Box()), hasHero: false)
        )
        let slide = stack.nav.delegate as? InteractiveSlideDismissal
        #expect(slide?.revealGeometry != nil, "precondition: opened as a window")
        #expect(slide?.heroLandingAcceptsHero?() == false)
    }

    // MARK: - Fixtures

    private final class Box: @unchecked Sendable {
        var row: CGRect? = CGRect(x: 16, y: 300, width: 370, height: 140)
        var concealed: [Bool] = []
        var events: [String] = []
    }

    private final class LandingScreen: UIViewController, CardCloseLanding {
        func cardCloseGeometry(dismissing feed: UIViewController) -> RevealGeometry? { nil }
        func clearLandingConcealment() {}
    }

    private func reveal(_ box: Box) -> TextRevealOrigin {
        TextRevealOrigin(
            rowFrame: { _ in box.row },
            captionEnd: nil,
            pageFit: .covering,
            setConcealed: { box.concealed.append($0) },
            dismissalDidEnd: { _ in box.events.append("row-dismiss") }
        )
    }

    private func origin(reveal: TextRevealOrigin?, hasHero: Bool = true) -> SnapFeedHeroOrigin {
        let post = GalleryPost(
            id: PostID(hasHero ? "m1" : "t1"),
            kind: hasHero ? .video : .text,
            isRepost: false,
            thumbnailURL: nil,
            caption: "a caption",
            publishedAtMS: 0
        )
        return SnapFeedHeroOrigin(
            post: post,
            stream: [post],
            hasHero: hasHero,
            cover: nil,
            style: .listMedia,
            frame: { _ in CGRect(x: 0, y: 0, width: 100, height: 100) },
            isOnScreen: { true },
            setConcealed: { _ in },
            textReveal: reveal
        )
    }

    @MainActor
    private final class Stack {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        let presenter = UIViewController()
        let nav: UINavigationController
        let tabs = UITabBarController()
        let builder = FeedFeatureBuilder(
            repository: SilentProvider(),
            imagePipeline: ImagePipeline(fetcher: PlaceholderImageFetcher())
        )

        init() {
            nav = UINavigationController(rootViewController: presenter)
            tabs.viewControllers = [nav]
            window.rootViewController = tabs
            window.isHidden = false
            window.layoutIfNeeded()
        }
    }
}

private struct SilentProvider: FeedProviding {
    func cachedFirstPage() async -> [FeedEntry]? { nil }
    func loadFirstPage() async throws -> FeedPage {
        try? await Task.sleep(nanoseconds: 5_000_000_000)
        return FeedPage(entries: [], nextPageToken: nil, isCold: false)
    }
    func loadPage(afterToken token: String) async throws -> FeedPage {
        FeedPage(entries: [], nextPageToken: nil, isCold: false)
    }
    func loadPost(_ id: PostID) async throws -> FeedEntry {
        throw FeedError.transport(message: "unused")
    }
}
