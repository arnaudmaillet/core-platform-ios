import CoreModels
import CoreNavigation
import FeedInterface
import MediaCore
import PostGrid
import Testing
import UIKit
@testable import Feed

/// Which TRANSITION a post is opened with, decided at the builder — the seam
/// every gallery (For You, profile, cluster) funnels through.
///
/// `PlainPushDismissalTests` pins the no-hero degradation and its gestures;
/// this suite pins the three elections it leaves open: a describable text row
/// gets the REVEAL rather than the bare slide, a gallery presenter splits its
/// dismissal axes across two drivers, and the flight's ownership of the stack
/// ends with the return — the delegate slot and the concealed tile both handed
/// back. All of it is stack-transaction and wiring state, per the headless
/// rule: nothing here waits on an animation.
@MainActor
struct HeroElectionTests {
    // MARK: - The reveal election

    /// A text post whose origin can describe its ROW opens as a reveal — the
    /// window, not the slide. The wiring is the assertion: the slide driver
    /// owns the stack AND carries the reveal geometry, and it presents.
    @Test func aTextRowWithARevealOpensAsAReveal() throws {
        let stack = Stack()
        stack.builder.presentSnapFeedHero(
            postIDs: [PostID("t1")], from: stack.presenter,
            origin: origin(hasHero: false, reveal: reveal())
        )

        let slide = try #require(stack.nav.delegate as? InteractiveSlideDismissal,
                                 "the reveal rides the slide driver's slot")
        #expect(slide.revealPresents, "the OPENING must be the reveal's, not just the close")
        #expect(slide.revealGeometry != nil, "a reveal with no geometry is a plain push")
    }

    /// The same post from a surface that cannot describe its row keeps the
    /// plain slide — the honest degradation, not a broken reveal.
    @Test func aTextRowWithoutARevealKeepsThePlainSlide() throws {
        let stack = Stack()
        stack.builder.presentSnapFeedHero(
            postIDs: [PostID("t1")], from: stack.presenter,
            origin: origin(hasHero: false, reveal: nil)
        )

        let slide = try #require(stack.nav.delegate as? InteractiveSlideDismissal)
        #expect(!slide.revealPresents)
        #expect(slide.revealGeometry == nil)
    }

    // MARK: - The gallery presenter's axis split

    /// ⚠️ A POST OPENED FROM THE PLACE PAGE GOES HOME ON BOTH AXES.
    ///
    /// It used to split them: the vertical grab flew home while the horizontal
    /// one ESCAPED past the gallery to the map. That read as a level being
    /// skipped, so a post opened from a place now returns to that place either
    /// way, and leaving the place for the map is the place's own gesture.
    ///
    /// Two drivers, not three: the flight, armed on both axes, and the
    /// card-shaped close beside it for the pages the flight refuses. A THIRD
    /// slide would be the escape come back — which is what this counts.
    @Test func aGalleryOpenedPostGoesHomeOnBothAxes() throws {
        let stack = Stack()
        let gallery = stack.builder.makeClusterGallery(
            postIDs: [PostID("g1")], title: "Paris", following: nil,
            feed: UIViewController(),
            // No map beneath this host: the page keeps the plain-slide
            // fallback, which is exactly the axis-split under test.
            mapReturn: { nil }
        )
        stack.nav.pushViewController(gallery, animated: false)
        #expect(gallery.navigationController === stack.nav, "precondition: gallery on the stack")

        stack.builder.presentSnapFeedHero(
            postIDs: [PostID("m1")], from: gallery, origin: origin(hasHero: true)
        )

        #expect(stack.nav.viewControllers.count == 3, "precondition: the post was pushed")
        #expect(stack.nav.viewControllers.contains(gallery),
                "nothing may drop the gallery from the stack any more")
        #expect(ZoomTransitionController.debugMostRecent != nil,
                "the flight controller was DEALLOCATED — its retainer cycle broke")
        // ⚠️ THE CARD-SHAPED CLOSE OWNS THE SLOT, not the flight — it is
        // installed last, on purpose, so that it hears every pop and hands the
        // ones it does not own straight back. A flight holding the slot itself
        // would never let a `.card` page begin a dismissal at all, which is the
        // defect this driver exists to cure.
        let owner = try #require(stack.nav.delegate as? InteractiveSlideDismissal,
                                 "the card-shaped close must be the one UIKit asks")
        #expect(owner.debugSavedDelegate is ZoomTransitionController,
                "it took the slot from the flight and saved nothing to give back")
        let pushed = try #require(stack.nav.viewControllers.last)
        let pans = pushed.view.gestureRecognizers?
            .filter { $0 is UIPanGestureRecognizer } ?? []
        #expect(pans.count == 2,
                "expected the flight and the card-shaped close, found \(pans.count)")
        let slides = pans.compactMap { $0.delegate as? InteractiveSlideDismissal }
        #expect(slides.count == 1, "a second slide is the escape come back")
        let close = try #require(slides.first)
        #expect(close.arbitratesWithHeroGrab,
                "the close must claim only the pages the flight refuses")

        // ⚠️ EVERY AXIS NEEDS A TENANT FOR EVERY KIND, and this is the property
        // that actually matters — not who is armed where.
        //
        // The flight refuses `.card` before it looks at an axis, so the
        // card-shaped close is the only driver that can take those pages; arm
        // it on one axis and the OTHER axis has nothing at all on it for a
        // viewer who has paged onto a text post. The drag then does nothing —
        // no window, no slide, no native pop, because this push disclaimed
        // that too. Shipped twice: once on the map, and once here when the
        // close's narrowing outlived the escape it was narrowed for.
        #expect(close.debugArmedAxes == [.horizontal, .vertical],
                "an axis with no card-shaped tenant is an axis a text page cannot leave on")
    }

    /// The control: an ordinary presenter's post carries exactly one pan —
    /// the grab, armed on both axes. Two here would be the escape leaking onto
    /// surfaces that have no gallery to escape past.
    @Test func anOrdinaryPresenterAttachesExactlyOneGrab() throws {
        let stack = Stack()
        stack.builder.presentSnapFeedHero(
            postIDs: [PostID("m1")], from: stack.presenter, origin: origin(hasHero: true)
        )

        let pushed = try #require(stack.nav.viewControllers.last)
        let pans = pushed.view.gestureRecognizers?
            .filter { $0 is UIPanGestureRecognizer } ?? []
        #expect(pans.count == 1)
    }

    // MARK: - The return hands everything back

    /// What the return CLOSES OUT: the delegate slot back to whoever owned it
    /// before the push, the tile unconcealed, the tab bar restored.
    ///
    /// The closure is invoked directly rather than through a real pop: an
    /// animated push never completes in a headless host (the repo's
    /// headless-transition rule), so UIKit defers the pop and `didShow`'s
    /// stack check reads the feed as still up — an artifact, not a behaviour.
    /// WHEN the closure fires is pinned where it is decidable:
    /// `ZoomTransitionRoutingTests.didShowRoutesToExactlyOneHook`
    /// (CoreNavigation). This pins WHAT it does.
    @Test func theReturnRestoresTheDelegateAndTheTile() throws {
        let stack = Stack()
        let previousDelegate = StubNavDelegate()
        stack.nav.delegate = previousDelegate
        var concealment: [Bool] = []
        stack.builder.presentSnapFeedHero(
            postIDs: [PostID("m1")], from: stack.presenter,
            origin: origin(hasHero: true, setConcealed: { concealment.append($0) })
        )
        let transition = try #require(stack.nav.delegate as? ZoomTransitionController)
        #expect(stack.nav.delegate !== previousDelegate, "precondition: the flight took the slot")
        #expect(stack.tabs.isTabBarHidden, "precondition: the push took the bar down")

        transition.onSourceReturned?()

        #expect(stack.nav.delegate === previousDelegate,
                "the delegate slot was not handed back to its previous owner")
        #expect(concealment.last == false,
                "the tile was left concealed after the flight that hid it ended")
        // The tab bar deliberately goes unasserted here: `restoreTabBar`
        // rightly refuses while a flight destination is still top, and a
        // headless host cannot complete the pop that would clear it (the
        // stuck animated push swallows even a `setViewControllers`). The
        // bar's return is observed where it is real — the Hero UI suites.
    }

    // MARK: - Fixtures

    @MainActor
    private final class Stack {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        let presenter = UIViewController()
        let nav: UINavigationController
        let tabs = UITabBarController()
        let builder = FeedFeatureBuilder(
            repository: SilentElectionProvider(),
            imagePipeline: ImagePipeline(fetcher: SilentElectionFetcher())
        )

        init() {
            nav = UINavigationController(rootViewController: presenter)
            tabs.viewControllers = [nav]
            window.rootViewController = tabs
            window.isHidden = false
            window.layoutIfNeeded()
        }
    }

    private final class StubNavDelegate: NSObject, UINavigationControllerDelegate {}

    private func origin(
        hasHero: Bool,
        reveal: TextRevealOrigin? = nil,
        setConcealed: @escaping (Bool) -> Void = { _ in }
    ) -> SnapFeedHeroOrigin {
        let post = GalleryPost(
            id: PostID(hasHero ? "m1" : "t1"),
            kind: hasHero ? .photo : .text,
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
            setConcealed: setConcealed,
            textReveal: reveal
        )
    }

    private func reveal() -> TextRevealOrigin {
        TextRevealOrigin(
            rowFrame: { _ in CGRect(x: 16, y: 300, width: 370, height: 120) },
            captionEnd: nil
        )
    }
}

private struct SilentElectionFetcher: ImageFetching {
    func fetchImageData(for url: URL) async throws -> Data { Data() }
}

/// Answers nothing, slowly — anything the destination renders came from the
/// projection, and the gallery's eager load cannot race the assertions.
private struct SilentElectionProvider: FeedProviding {
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

/// A marker's flight source, reduced to the four answers `presentSnapFeedHero`
/// actually needs to arm an escape. Nothing here flies: the suite asserts the
/// WIRING (which drivers exist, and how they arbitrate), per this file's
/// headless rule that nothing waits on an animation.
@MainActor
private final class StubZoomSource: ZoomTransitionSource {
    func zoomHeroFrame(in container: UICoordinateSpace) -> CGRect {
        CGRect(x: 0, y: 0, width: 56, height: 56)
    }

    var zoomSourceIsOnScreen: Bool { true }
    func makeZoomFlightCard() -> any ZoomFlightCard { StubFlightCard() }
    func setZoomSourceHidden(_ hidden: Bool) {}
}

private final class StubFlightCard: UIView, ZoomFlightCard {
    var zoomRestingCornerRadius: CGFloat { 12 }
    var zoomRestingChrome: UIView? { nil }
    func setZoomCornerRadius(_ radius: CGFloat) {}
}
