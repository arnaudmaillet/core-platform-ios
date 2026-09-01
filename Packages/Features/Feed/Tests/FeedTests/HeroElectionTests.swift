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

    /// A post opened from the PLACE GALLERY carries three drivers where an
    /// ordinary presenter's carries one: the vertical grab keeps the tile
    /// morph, a horizontal one escapes past the gallery, and a vertical
    /// card-shaped close catches the pages the grab refuses.
    @Test func aGalleryPresenterSplitsItsDismissalAxes() throws {
        let stack = Stack()
        let gallery = stack.builder.makeClusterGallery(
            postIDs: [PostID("g1")], title: "Paris", following: nil,
            feed: UIViewController(),
            // No map beneath this host: the page keeps the plain-slide
            // fallback, which is exactly the axis-split under test.
            mapReturn: { _ in nil }
        )
        stack.nav.pushViewController(gallery, animated: false)
        #expect(gallery.navigationController === stack.nav, "precondition: gallery on the stack")

        stack.builder.presentSnapFeedHero(
            postIDs: [PostID("m1")], from: gallery, origin: origin(hasHero: true)
        )

        #expect(stack.nav.viewControllers.count == 3, "precondition: the post was pushed")
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
        #expect(pans.count == 3,
                "expected the vertical grab, the horizontal escape and the vertical card-shaped close, found \(pans.count)")
    }

    /// With a MARKER to fly home to, the horizontal escape gains a second
    /// tenant: the flight. The two share the axis and are told apart by KIND —
    /// the flight refuses a `.card` dismissal, the slide refuses everything
    /// else — so exactly one claims any drag.
    ///
    /// ⚠️ The sibling above deliberately yields no source, so it exercises the
    /// FALLBACK and can say nothing about this. Without a fixture that returns
    /// a real one, the flight escape would ship with no headless coverage at
    /// all while the suite stayed green.
    @Test func aMarkerToFlyToPutsAFlightBesideTheEscape() throws {
        let stack = Stack()
        let gallery = stack.builder.makeClusterGallery(
            postIDs: [PostID("g1")], title: "Paris", following: nil,
            feed: UIViewController(),
            mapReturn: { _ in StubZoomSource() }
        )
        stack.nav.pushViewController(gallery, animated: false)
        stack.builder.presentSnapFeedHero(
            postIDs: [PostID("m1")], from: gallery, origin: origin(hasHero: true)
        )

        let pushed = try #require(stack.nav.viewControllers.last)
        let pans = pushed.view.gestureRecognizers?
            .filter { $0 is UIPanGestureRecognizer } ?? []
        #expect(pans.count == 4,
                "expected the vertical grab, the horizontal flight, the card-shaped escape beside it and the vertical card-shaped close, found \(pans.count)")

        // The arbitration IS the safety: without it two drivers self-gate on
        // the same axis and race for the same drag.
        // ⚠️ BOTH slides arbitrate here, and by count rather than by identity:
        // the two are indistinguishable from outside except by the axis they
        // were armed on, which they do not publish. The escape claims only
        // `.card` because the flight beside it owns the media pages; the
        // vertical close claims only `.card` because the zoom grab does.
        let slides = pans.compactMap { $0.delegate as? InteractiveSlideDismissal }
        #expect(slides.count == 2, "expected the escape and the card-shaped close")
        #expect(slides.filter { $0.arbitratesWithHeroGrab }.count == 2,
                "an unarbitrated slide would claim media pages out from under the flight")
    }

    /// And the fallback keeps the slide UNARBITRATED. A marker that has left
    /// the map yields no flight, so a slide that still refused everything but
    /// `.card` would leave a media post with no horizontal way out at all —
    /// the fallback answering for the one case it is not the fallback for.
    @Test func withNoMarkerTheEscapeClaimsEveryKind() throws {
        let stack = Stack()
        let gallery = stack.builder.makeClusterGallery(
            postIDs: [PostID("g1")], title: "Paris", following: nil,
            feed: UIViewController(), mapReturn: { _ in nil }
        )
        stack.nav.pushViewController(gallery, animated: false)
        stack.builder.presentSnapFeedHero(
            postIDs: [PostID("m1")], from: gallery, origin: origin(hasHero: true)
        )

        let pushed = try #require(stack.nav.viewControllers.last)
        let pans = pushed.view.gestureRecognizers?
            .filter { $0 is UIPanGestureRecognizer } ?? []
        // Exactly one of the two still arbitrates — the vertical close, which
        // shares its axis with the zoom grab either way. The escape does not,
        // because with no flight beside it there is nothing to arbitrate WITH
        // and a media post would otherwise have no horizontal way out at all.
        let slides = pans.compactMap { $0.delegate as? InteractiveSlideDismissal }
        #expect(slides.count == 2)
        #expect(slides.filter { $0.arbitratesWithHeroGrab }.count == 1)
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
