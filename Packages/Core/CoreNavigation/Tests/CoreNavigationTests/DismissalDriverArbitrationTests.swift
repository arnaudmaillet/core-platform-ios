@testable import CoreNavigation
import Testing
import UIKit

/// Which driver animates a screen away, when two are attached to it.
///
/// ## Why this suite exists
///
/// The feed a post opens into is a PAGER, so the post being dismissed is
/// routinely not the post that opened — and the two kinds of close are not
/// interchangeable. A hero flies a piece of MEDIA between two places that both
/// have it; a card-shaped close carries a whole row, which is what a text post
/// needs because it has no media at all.
///
/// Both drivers are therefore attached to one screen, and one navigation
/// delegate slot serves both. Every defect that seam produced was a
/// disagreement about the same question — which post is on screen, and what
/// does it travel as — asked at three places: the two grabs' begin gates, and
/// the animator vended here. These pin the third, because it is the one that
/// can be asked without a finger.
///
/// The two shipped regressions this would have caught, both reported from a
/// device rather than by a test:
///
/// * a card close's preparation running for a HERO pop, which concealed the
///   row the flight was landing on — "the hero animation does not work any
///   more, no animation at all";
/// * the preparation running twice for one swipe, undoing its own swap.
@MainActor
struct DismissalDriverArbitrationTests {
    /// The smallest screen that can answer the one question the arbitration
    /// asks, with the answer settable per test.
    private final class StubFeed: UIViewController, ZoomTransitionDestination {
        var kind: ZoomDismissalKind = .hero

        var zoomDismissalKind: ZoomDismissalKind { kind }
        var isReadyForInteractiveDismissal: Bool { true }
        func zoomTargetFrame(in container: UICoordinateSpace) -> CGRect { .zero }
        func zoomFlightChrome() -> UIView? { nil }
        func setZoomContentHidden(_ hidden: Bool) {}
        func zoomTransitionDidEnd() {}
        func setContentScrollEnabled(_ enabled: Bool) {}
    }

    /// Stands in for the driver this one displaced when it took the delegate
    /// slot. Records what it was asked for, because "did not forward" and
    /// "forwarded and got nil" are different failures.
    private final class SavedDelegate: NSObject, UINavigationControllerDelegate {
        let animator = UIViewControllerAnimatedTransitioningStub()
        /// Whether it has anything to say about this pop. False is the case
        /// that mattered: a delegate holding the slot for a DIFFERENT screen
        /// declines, and a decline is not permission to stop asking.
        var answers = true
        private(set) var animatorAsks = 0
        private(set) var didShows = 0
        private(set) var interactionAsks = 0

        func navigationController(
            _ navigationController: UINavigationController,
            interactionControllerFor animationController: any UIViewControllerAnimatedTransitioning
        ) -> (any UIViewControllerInteractiveTransitioning)? {
            interactionAsks += 1
            return nil
        }

        func navigationController(
            _ navigationController: UINavigationController,
            animationControllerFor operation: UINavigationController.Operation,
            from fromVC: UIViewController,
            to toVC: UIViewController
        ) -> (any UIViewControllerAnimatedTransitioning)? {
            animatorAsks += 1
            return answers ? animator : nil
        }

        func navigationController(
            _ navigationController: UINavigationController,
            didShow viewController: UIViewController,
            animated: Bool
        ) {
            didShows += 1
        }
    }

    final class UIViewControllerAnimatedTransitioningStub:
        NSObject, UIViewControllerAnimatedTransitioning {
        func transitionDuration(
            using transitionContext: (any UIViewControllerContextTransitioning)?
        ) -> TimeInterval { 0 }
        func animateTransition(using transitionContext: any UIViewControllerContextTransitioning) {}
    }

    private struct Rig {
        let driver: InteractiveSlideDismissal
        let nav: UINavigationController
        let feed: StubFeed
        let saved: SavedDelegate
    }

    private func rig(kind: ZoomDismissalKind) -> Rig {
        let root = UIViewController()
        let feed = StubFeed()
        feed.kind = kind
        let nav = UINavigationController(rootViewController: root)
        let saved = SavedDelegate()
        nav.delegate = saved
        nav.viewControllers = [root, feed]
        let driver = InteractiveSlideDismissal()
        driver.attach(to: feed, axes: [.horizontal, .vertical])
        driver.arbitratesWithHeroGrab = true
        driver.install(on: nav)
        return Rig(driver: driver, nav: nav, feed: feed, saved: saved)
    }

    private func popAnimator(_ rig: Rig) -> (any UIViewControllerAnimatedTransitioning)? {
        rig.driver.navigationController(
            rig.nav, animationControllerFor: .pop, from: rig.feed, to: rig.nav.viewControllers[0]
        )
    }

    // MARK: - Who animates

    /// ⚠️ A POST THAT FLIES GOES BACK TO THE DELEGATE THIS DRIVER DISPLACED.
    ///
    /// One slot, two drivers: this one holds it for the whole of the screen's
    /// life, and a hero's animator lives in the other. Forwarding is how the
    /// screen keeps both.
    @Test func aPostThatFliesIsAnimatedByTheDisplacedDelegate() {
        let rig = rig(kind: .hero)

        let animator = popAnimator(rig)

        #expect(rig.saved.animatorAsks == 1)
        #expect(animator === rig.saved.animator)
    }

    /// And a post that travels as a card is animated HERE — the same question,
    /// the other answer.
    @Test func aPostThatTravelsAsACardIsAnimatedHere() {
        let rig = rig(kind: .card)
        rig.driver.revealGeometry = RevealGeometry(sourceFrame: { _ in .zero }, sourceCornerRadius: 0)

        let animator = popAnimator(rig)

        #expect(rig.saved.animatorAsks == 0)
        #expect(animator is RevealPopAnimator)
    }

    /// ⚠️ ASKED OF THE POST, NOT OF WHO IS DRIVING — because a back-button pop
    /// has no driver at all and must still leave as the right kind.
    ///
    /// Nothing has grabbed anything in any of these tests; the answers above
    /// come from the destination alone.
    @Test func aCardCloseWithNoGeometryStillDoesNotBecomeAFlight() {
        let rig = rig(kind: .card)

        let animator = popAnimator(rig)

        #expect(rig.saved.animatorAsks == 0)
        // The slide's own pop animator is file-private, so it is named by what
        // it is not: ours, and not the flight's.
        #expect(animator != nil)
        #expect(animator is RevealPopAnimator == false)
        #expect(animator !== rig.saved.animator)
    }

    // MARK: - Preparation

    /// ⚠️ THE PREPARATION RUNS BEFORE THE GEOMETRY IS READ.
    ///
    /// What a card-shaped close carries belongs to the post being DISMISSED,
    /// and on a pager that is not the post the screen opened with — so the
    /// geometry is built at the dismissal rather than carried from the opening.
    /// A hook that ran afterwards would decide nothing.
    @Test func theGeometryBuiltByThePreparationIsTheOneUsed() {
        let rig = rig(kind: .card)
        rig.driver.prepareForDismissal = { [weak driver = rig.driver] _ in
            driver?.revealGeometry = RevealGeometry(
                sourceFrame: { _ in .zero }, sourceCornerRadius: 0
            )
        }

        #expect(rig.driver.revealGeometry == nil)
        let animator = popAnimator(rig)

        #expect(animator is RevealPopAnimator)
    }

    /// ⚠️ AND IT RUNS FOR A HERO POP TOO, which is why the hook itself has to
    /// decide what it is willing to do.
    ///
    /// This is the shipped regression: the hook moved a card into the departure
    /// slot and CONCEALED the row there — correct for a card close, and for a
    /// flight it hid the row the hero was landing on. Reported as the hero
    /// having stopped animating altogether.
    ///
    /// The driver cannot filter it: a pop is every dismissal there is, and the
    /// driver does not know what the hook intends. So the contract is stated
    /// here, and the caller gates on the same `zoomDismissalKind` the drivers
    /// do.
    @Test func thePreparationIsAlsoAskedForAPopItWillNotAnimate() {
        let rig = rig(kind: .hero)
        var asks = 0
        rig.driver.prepareForDismissal = { _ in asks += 1 }

        _ = popAnimator(rig)

        #expect(asks == 1)
    }

    // MARK: - The rest of the slot

    /// ⚠️ `didShow` IS NEWS, NOT A CHOICE, so it is forwarded whoever animated.
    ///
    /// Displacing a delegate takes its animator calls — which this driver
    /// answers or forwards — and silently takes its news as well. The flight
    /// controller keeps its own bookkeeping on this call, and losing it leaks
    /// that state for the life of the screen.
    @Test func theDisplacedDelegateStillHearsWhatShowed() {
        let rig = rig(kind: .card)

        rig.driver.navigationController(rig.nav, didShow: rig.feed, animated: true)

        #expect(rig.saved.didShows == 1)
    }

    /// An interaction controller is ours only while one of ours is driving.
    /// Pairing this driver's percent scrub with an animator that came from the
    /// saved delegate would scrub someone else's flight.
    @Test func theInteractionFollowsWhoeverAnimates() {
        let rig = rig(kind: .hero)

        let interaction = rig.driver.navigationController(
            rig.nav, interactionControllerFor: rig.saved.animator
        )

        // Nothing of ours is driving, so the answer is whatever the displaced
        // delegate says — here, nothing.
        #expect(interaction == nil)
    }

    /// ⚠️ A SECOND PRESENTATION FORWARDS TO THE SECOND OWNER.
    ///
    /// The saved delegate is handed back by `didShow` when the screen leaves
    /// the stack, and `didShow` does not always arrive — measured in a live
    /// session, on a card-shaped close that completed perfectly otherwise. The
    /// slot then stays taken and the capture stays set, so the NEXT opening
    /// installs a fresh flight that this driver refuses to notice: the pop asks
    /// to be forwarded to a controller belonging to the previous screen, and
    /// with nothing to forward to it falls through to its own animator. The
    /// trace reads `kind=hero` and `reveal animate` on the same pop — the
    /// window closing a post that wanted to fly, reported as the grab not
    /// working.
    ///
    /// The opening says so, because only the opening knows: a re-assert during
    /// the screen's life must NOT move the capture (see `install`).
    @Test func aSecondPresentationForwardsToWhoeverOwnsTheStackNow() {
        let rig = rig(kind: .hero)
        // A close that never reported itself: the slot is still ours.
        let second = SavedDelegate()
        rig.nav.delegate = second

        rig.driver.resetForNewPresentation()
        rig.driver.install(on: rig.nav)
        let animator = popAnimator(rig)

        #expect(second.animatorAsks == 1, "the pop was not forwarded to the current owner")
        #expect(animator === second.animator)
        #expect(rig.saved.animatorAsks == 0, "the previous screen's controller was asked instead")
    }

    /// And a re-assert during the screen's life leaves the capture alone —
    /// which is what keeps a three-level unwind landing on the right screen.
    @Test func aReassertDoesNotMoveTheCapture() {
        let rig = rig(kind: .hero)
        let transient = SavedDelegate()
        rig.nav.delegate = transient

        rig.driver.install(on: rig.nav)
        _ = popAnimator(rig)

        #expect(transient.animatorAsks == 0, "a transient delegate was captured as the owner")
        #expect(rig.saved.animatorAsks == 1)
    }

    /// ⚠️ AND A NEW PRESENTATION RUNS NONE OF THE LAST ONE'S PREPARATION.
    ///
    /// The hook is set by the flight path only. Left in place, a WINDOW's close
    /// ran it — and what it does is rebuild the geometry for a different post,
    /// clearing it when it cannot. The trace reads `kind=card geometry=false`
    /// and the window closes as a flat slide, which is the third defect this
    /// one object's memory has produced.
    @Test func aNewPresentationRunsNoneOfTheLastOnesPreparation() {
        let rig = rig(kind: .card)
        var stale = 0
        rig.driver.prepareForDismissal = { _ in stale += 1 }
        rig.driver.revealGeometry = RevealGeometry(sourceFrame: { _ in .zero }, sourceCornerRadius: 0)

        rig.driver.resetForNewPresentation()
        _ = popAnimator(rig)

        #expect(stale == 0, "the previous presentation's preparation ran")
        #expect(rig.driver.revealGeometry == nil, "the previous presentation's geometry survived")
        #expect(rig.driver.revealPresents == false)
    }

    /// ⚠️ AN ANIMATOR THIS DRIVER BUILT IS NEVER DRIVEN BY ANYONE ELSE.
    ///
    /// The forwarding above is for animators that came FROM the displaced
    /// delegate. Asking it about one of ours invites it to answer about its own
    /// flights: a flight controller can hand back an interaction controller,
    /// which then stages a hero of its own and waits for a finger that does not
    /// exist. The pop starts, nothing advances it, and it never completes —
    /// measured as a closed post's navigation bar left standing over the grid.
    @Test func nobodyElseGetsToDriveOurOwnAnimator() {
        let rig = rig(kind: .card)
        rig.driver.revealGeometry = RevealGeometry(sourceFrame: { _ in .zero }, sourceCornerRadius: 0)
        let ours = popAnimator(rig)
        #expect(ours is RevealPopAnimator)

        let interaction = rig.driver.navigationController(
            rig.nav, interactionControllerFor: ours!
        )

        #expect(interaction == nil)
        #expect(rig.saved.interactionAsks == 0, "the displaced delegate was asked to drive our pop")
    }

    /// ⚠️ A GEOMETRY IS NOT AN OPENING.
    ///
    /// A media post carries one now, for the case where the viewer pages onto a
    /// text post before closing — so deciding the PUSH from its presence would
    /// put a reveal over a flight's opening. Only a screen that was opened as a
    /// window says so.
    @Test func aGeometryAloneDoesNotClaimThePush() {
        let rig = rig(kind: .card)
        rig.driver.revealGeometry = RevealGeometry(sourceFrame: { _ in .zero }, sourceCornerRadius: 0)

        let push = rig.driver.navigationController(
            rig.nav, animationControllerFor: .push,
            from: rig.nav.viewControllers[0], to: rig.feed
        )
        #expect(push is RevealPresentAnimator == false)

        rig.driver.revealPresents = true
        let claimed = rig.driver.navigationController(
            rig.nav, animationControllerFor: .push,
            from: rig.nav.viewControllers[0], to: rig.feed
        )
        #expect(claimed is RevealPresentAnimator)
    }

    // MARK: - A decline is not an answer

    /// ⚠️ A FORWARD THAT COMES BACK NIL MUST NOT STRAND A LIVE GRAB.
    ///
    /// Forwarding exists so a post that FLIES reaches the flight this driver
    /// displaced. But nil from that delegate is not "no opinion" — it is
    /// UIKit's own default pop, which is not interactive. Returned as though it
    /// were an answer, the grab created moments earlier drove nothing and the
    /// screen slid away as if there had been no gesture: filmed on a post
    /// opened as a REVEAL, whose displaced delegate belongs to a different
    /// screen entirely and has nothing to say about this pop.
    @Test func aDeclinedForwardLeavesTheLiveGrabDriving() async {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        let feed = StubFeed()
        let nav = UINavigationController(rootViewController: UIViewController())
        nav.pushViewController(feed, animated: false)
        window.rootViewController = nav
        window.makeKeyAndVisible()
        window.layoutIfNeeded()

        // The delegate is in the slot BEFORE the install, which is what makes
        // it the saved one: `install` captures whoever owned the stack and
        // takes the slot from them.
        let saved = SavedDelegate()
        saved.answers = false
        nav.delegate = saved

        let slide = InteractiveSlideDismissal()
        slide.attach(to: feed, axes: [.horizontal])
        slide.install(on: nav)
        #expect(slide.debugSavedDelegate === saved, "precondition: it has someone to forward to")

        let driven = await slide.debugPerformSwipe(peakProgress: 0.9)

        #expect(saved.animatorAsks > 0, "it must still ASK — the flight case depends on it")
        #expect(driven, "the finger drove nothing: the decline was taken for an answer")
    }

    // MARK: - An axis taken from the hero

    /// ⚠️ A PHOTOGRAPH'S DOWNWARD CLOSE THE HERO WAS TOLD TO LEAVE ALONE IS
    /// NEVER HANDED TO IT.
    ///
    /// The map's hierarchy marker: rightward a photograph flies home to the
    /// marker, downward every post closes as the card onto the place page's
    /// Activity row. The pop's forward used to ask only the post — a `.hero`
    /// post went to the flight whatever the axis, so the downward close flew a
    /// card onto a Discover tile while this driver's window was live.
    @Test func aLiveGrabOnAnAxisTakenFromTheHeroIsNotForwarded() async {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        let feed = StubFeed()
        feed.kind = .hero
        let nav = UINavigationController(rootViewController: UIViewController())
        nav.pushViewController(feed, animated: false)
        window.rootViewController = nav
        window.makeKeyAndVisible()
        window.layoutIfNeeded()

        let saved = SavedDelegate()
        nav.delegate = saved

        let slide = InteractiveSlideDismissal()
        slide.attach(to: feed, axes: [.horizontal, .vertical])
        slide.arbitratesWithHeroGrab = true
        slide.heroClaimsAxis = { $0 != .vertical }
        slide.install(on: nav)

        let driven = await slide.debugPerformSwipe(peakProgress: 0.9, axis: .vertical)

        #expect(saved.animatorAsks == 0, "the flight was handed a downward close it had given up")
        #expect(driven)
    }

    /// And the back button keeps its flight: a pop with no gesture travels the
    /// platform's own direction, which the hero still claims.
    @Test func aBackButtonPopStillFliesWhenOnlyTheVerticalAxisWasTaken() {
        let rig = rig(kind: .hero)
        rig.driver.heroClaimsAxis = { $0 != .vertical }

        let animator = popAnimator(rig)

        #expect(rig.saved.animatorAsks == 1)
        #expect(animator === rig.saved.animator)
    }

    /// The card-only staging gate opens for the axis the hero gave up, and only
    /// for it — see `closeCarriesCard`.
    @Test func theCardGateOpensOnlyOnTheAxisTakenFromTheHero() {
        let rig = rig(kind: .hero)
        #expect(!rig.driver.closeCarriesCard(of: rig.feed, axis: .vertical))
        rig.driver.heroClaimsAxis = { $0 != .vertical }
        #expect(rig.driver.closeCarriesCard(of: rig.feed, axis: .vertical))
        #expect(!rig.driver.closeCarriesCard(of: rig.feed, axis: .horizontal))
        rig.feed.kind = .card
        #expect(rig.driver.closeCarriesCard(of: rig.feed, axis: .horizontal))
    }

    /// And the narrowing: a pop with NO gesture keeps forwarding exactly as it
    /// did, nil included. There is nothing being driven that a decline could
    /// strand, and the animator this would otherwise fall through to is chosen
    /// from a geometry a back-button pop never re-staged.
    @Test func aBackButtonPopStillForwardsEvenADecline() {
        let rig = rig(kind: .hero)
        rig.saved.answers = false
        #expect(popAnimator(rig) == nil)
        #expect(rig.saved.animatorAsks == 1)
    }
}

/// Which of two grabs on one screen claims a drag.
///
/// The animator seam above decides who ANIMATES; this decides who DRIVES. The
/// two questions are asked in different places and both must answer the same
/// way, because a drag claimed by the driver that will not animate it reads on
/// screen as a dead gesture — the finger moves and nothing follows.
///
/// Both gates ask the destination the same `zoomDismissalKind` from opposite
/// sides, so exactly one of them claims any given grab. These pin that the two
/// halves cover the space with no gap and no overlap.
@MainActor
struct DismissalGrabArbitrationTests {
    /// A real recognizer answers zero velocity outside a real touch, and the
    /// gates read velocity to pick an axis — so the hand is faked, and only the
    /// hand.
    private final class FakePan: UIPanGestureRecognizer {
        var fakeVelocity: CGPoint = CGPoint(x: 0, y: 900)
        var fakeLocation: CGPoint = CGPoint(x: 200, y: 400)
        var fakeTranslation: CGPoint = .zero
        override func velocity(in view: UIView?) -> CGPoint { fakeVelocity }
        override func location(in view: UIView?) -> CGPoint { fakeLocation }
        override func translation(in view: UIView?) -> CGPoint { fakeTranslation }
    }

    private final class StubFeed: UIViewController, ZoomTransitionDestination {
        var kind: ZoomDismissalKind = .hero
        /// Stands for a tenant under the finger — a carousel with a photograph
        /// to its left answers `false` here, which is exactly what the snap
        /// feed's gate does.
        var horizontalPermitted = true
        /// Every location the horizontal question was asked at, so a test can
        /// tell "refused" from "never asked".
        private(set) var horizontalAsks: [CGPoint] = []

        var zoomDismissalKind: ZoomDismissalKind { kind }
        func zoomHorizontalDismissalPermitted(at location: CGPoint, in view: UIView) -> Bool {
            horizontalAsks.append(location)
            return horizontalPermitted
        }
        var isReadyForInteractiveDismissal: Bool { true }
        func zoomTargetFrame(in container: UICoordinateSpace) -> CGRect { .zero }
        func zoomFlightChrome() -> UIView? { nil }
        func setZoomContentHidden(_ hidden: Bool) {}
        func zoomTransitionDidEnd() {}
        func setContentScrollEnabled(_ enabled: Bool) {}
    }

    private final class StubSource: NSObject, ZoomTransitionSource {
        var landingAcceptsHero = true
        var zoomLandingAcceptsHero: Bool { landingAcceptsHero }
        func zoomHeroFrame(in container: UICoordinateSpace) -> CGRect { .zero }
        var zoomSourceIsOnScreen: Bool { true }
        func makeZoomFlightCard() -> any ZoomFlightCard { StubCard() }
        func setZoomSourceHidden(_ hidden: Bool) {}
        func zoomLiveMediaSurfaceIfReady() -> UIView? { nil }
    }

    private final class StubCard: UIView, ZoomFlightCard {
        var zoomLiveMediaSurface: UIView?
        var zoomRestingCornerRadius: CGFloat { 12 }
        var zoomRestingChrome: UIView? { nil }
        func setZoomCornerRadius(_ radius: CGFloat) {}
        func adoptZoomLiveMediaView(_ view: UIView) {}
        func prepareZoomLiveMediaForFlight(destinationSize: CGSize) {}
    }

    /// A screen with BOTH grabs live on it, which is the only configuration
    /// any of this is about.
    private struct Rig {
        let feed: StubFeed
        let hero: ZoomDismissInteractionController
        let slide: InteractiveSlideDismissal
        let source: StubSource
        let nav: UINavigationController
    }

    private func rig(kind: ZoomDismissalKind, arbitrates: Bool = true) -> Rig {
        let feed = StubFeed()
        feed.kind = kind
        feed.view.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        let nav = UINavigationController(rootViewController: UIViewController())
        nav.viewControllers = [nav.viewControllers[0], feed]
        let source = StubSource()
        let hero = ZoomDismissInteractionController()
        hero.attach(to: feed.view, source: source, destination: feed) {}
        let slide = InteractiveSlideDismissal()
        slide.attach(to: feed, axes: [.horizontal, .vertical])
        slide.arbitratesWithHeroGrab = arbitrates
        slide.install(on: nav)
        return Rig(feed: feed, hero: hero, slide: slide, source: source, nav: nav)
    }

    /// ⚠️ EXACTLY ONE DRIVER CLAIMS ANY DRAG — the invariant the whole pair
    /// exists to hold, and it has now been broken in BOTH directions.
    ///
    /// Both refusing: the hero declines a landing it cannot draw and the slide
    /// was never told, so it reads "no opinion" as "the hero is taking it".
    /// Nothing begins, no interactive pop is started, and the screen leaves on
    /// UIKit's own edge-swipe animation.
    ///
    /// Both claiming: a landing predicate left over from a PREVIOUS
    /// presentation answers false about a post two screens ago, so the slide
    /// contests a drag the hero is also taking. Whichever recognizer begins
    /// first pops, and if it is the slide the geometry is nil and the close is
    /// a plain slide.
    ///
    /// Swept rather than written out case by case: the two answers are
    /// independent and the failures were both in a corner nobody enumerated.
    @Test func exactlyOneDriverClaimsEveryCombination() {
        for kind in [ZoomDismissalKind.hero, .card] {
            for landingAccepts in [true, false] {
                let rig = rig(kind: kind)
                rig.source.landingAcceptsHero = landingAccepts
                rig.slide.heroLandingAcceptsHero = { landingAccepts }
                let pan = FakePan()

                let hero = rig.hero.gestureRecognizerShouldBegin(pan)
                let slide = rig.slide.gestureRecognizerShouldBegin(pan)
                #expect(hero != slide,
                        "kind=\(kind) landingAccepts=\(landingAccepts) hero=\(hero) slide=\(slide)")
            }
        }
    }

    /// ⚠️ THE MAP'S SHAPE: THE SAME PHOTOGRAPH IS THE HERO'S RIGHTWARD AND THE
    /// SLIDE'S DOWNWARD, and still exactly one driver claims each drag.
    ///
    /// The downward landing (the place page) refuses a hero, and the slide asks
    /// that same answer per axis (`heroClaimsAxis`) — one predicate from both
    /// sides, swept over both kinds and both axes.
    @Test func anAxisTakenFromTheHeroHasExactlyOneDriver() {
        for kind in [ZoomDismissalKind.hero, .card] {
            for velocity in [CGPoint(x: 900, y: 0), CGPoint(x: 0, y: 900)] {
                let rig = rig(kind: kind)
                let vertical = velocity.y > 0
                // Rightward the landing is the marker, which takes a flight;
                // downward it is the place page, which does not.
                rig.source.landingAcceptsHero = !vertical
                rig.slide.heroClaimsAxis = { [source = rig.source] axis in
                    axis != .vertical || source.landingAcceptsHero
                }
                let pan = FakePan()
                pan.fakeVelocity = velocity

                let hero = rig.hero.gestureRecognizerShouldBegin(pan)
                let slide = rig.slide.gestureRecognizerShouldBegin(pan)
                #expect(hero != slide, "kind=\(kind) vertical=\(vertical) hero=\(hero) slide=\(slide)")
                if vertical {
                    #expect(slide, "kind=\(kind): the downward close is not the card's")
                }
            }
        }
    }

    /// ⚠️ AND A NEW PRESENTATION FORGETS THE LAST ONE'S ANSWER. This driver is
    /// one retained instance for the screen's life, so a predicate left behind
    /// is asked again about a post that is no longer on screen — which is how
    /// "both claiming" above is reached in the app.
    @Test func aNewPresentationForgetsThePreviousLandingPredicate() {
        let slide = InteractiveSlideDismissal()
        slide.heroLandingAcceptsHero = { false }
        slide.heroClaimsAxis = { _ in false }
        slide.resetForNewPresentation()
        #expect(slide.heroLandingAcceptsHero == nil)
        #expect(slide.heroClaimsAxis == nil)
    }

    /// ⚠️ A POST WITH MEDIA IS THE HERO GRAB'S, AND THE SLIDE STANDS DOWN.
    @Test func aPostThatFliesIsGrabbedByTheHero() {
        let rig = rig(kind: .hero)
        let pan = FakePan()

        #expect(rig.hero.gestureRecognizerShouldBegin(pan) == true)
        #expect(rig.slide.gestureRecognizerShouldBegin(pan) == false)
    }

    /// ⚠️ AND A TEXT POST IS THE SLIDE'S, with the hero standing down — the
    /// same question, answered from the other side.
    @Test func aPostWithNothingToFlyIsGrabbedByTheSlide() {
        let rig = rig(kind: .card)
        let pan = FakePan()

        #expect(rig.hero.gestureRecognizerShouldBegin(pan) == false)
        #expect(rig.slide.gestureRecognizerShouldBegin(pan) == true)
    }

    /// ⚠️ EXACTLY ONE CLAIMS ANY GRAB — no kind is refused by both.
    ///
    /// A gap here is not a crash, it is a dead drag: the finger moves, nothing
    /// follows, and the screen looks frozen rather than broken.
    @Test func everyKindOfPostHasExactlyOneDriver() {
        for kind in [ZoomDismissalKind.hero, .card] {
            let rig = rig(kind: kind)
            let pan = FakePan()
            let claims = [
                rig.hero.gestureRecognizerShouldBegin(pan),
                rig.slide.gestureRecognizerShouldBegin(pan),
            ].filter { $0 }
            #expect(claims.count == 1, "kind \(kind) has \(claims.count) drivers")
        }
    }

    /// ⚠️ A SCREEN THAT FLIES NOTHING AT ALL KEEPS CLAIMING ITS DRAGS.
    ///
    /// This driver serves screens with no hero anywhere near them, and a
    /// destination with no opinion answers `.hero` — so the gate asks for
    /// `.card` only when it was told it shares the screen. Reading "not card"
    /// as "stand down" would have muted every one of those screens' swipes.
    @Test func aLoneSlideIsNotBoundByTheArbitration() {
        let rig = rig(kind: .hero, arbitrates: false)

        #expect(rig.slide.gestureRecognizerShouldBegin(FakePan()) == true)
    }

    /// The kind is read at the GRAB, not at the attach — the whole reason the
    /// question exists is that the feed is a pager and the post changes under
    /// both drivers after they are installed.
    @Test func pagingOntoAnotherKindOfPostMovesTheGrab() {
        let rig = rig(kind: .hero)
        let pan = FakePan()
        #expect(rig.hero.gestureRecognizerShouldBegin(pan) == true)

        rig.feed.kind = .card

        #expect(rig.hero.gestureRecognizerShouldBegin(pan) == false)
        #expect(rig.slide.gestureRecognizerShouldBegin(pan) == true)
    }

    // MARK: - The screen's tenants

    /// ⚠️ A DRAG THE SCREEN GIVES TO A TENANT IS CLAIMED BY NO DRIVER — whoever
    /// opened the screen, whatever the post travels as.
    ///
    /// The shipped regression: open For You's Following list on a TEXT row (the
    /// window, this suite's slide), page down to a carousel, drag rightward on
    /// its second photograph — the window was grabbed instead of going back a
    /// photograph. The same carousel reached from a MEDIA row (the hero)
    /// paged. The hero always asked the screen; the slide asked only when its
    /// owner had opted in, and For You's text window, the map's card close and
    /// every other card close had not.
    ///
    /// Swept over every configuration a slide is armed in across the app — lone,
    /// arbitrating over a text post, arbitrating with a landing that refuses the
    /// hero, arbitrating with an axis taken from the hero — because the defect
    /// lived in the configurations nobody enumerated.
    @Test func aDragTheScreenGivesToATenantIsClaimedByNoDriver() {
        typealias Arming = (name: String, kind: ZoomDismissalKind, arbitrates: Bool,
                            configure: (InteractiveSlideDismissal) -> Void)
        let armings: [Arming] = [
            ("lone slide", .hero, false, { _ in }),
            ("text post (For You text window)", .card, true, { _ in }),
            ("landing refuses the hero (list row)", .hero, true, { $0.heroLandingAcceptsHero = { false } }),
            ("axis taken from the hero (map)", .hero, true, { $0.heroClaimsAxis = { _ in false } }),
        ]
        for arming in armings {
            let rig = rig(kind: arming.kind, arbitrates: arming.arbitrates)
            arming.configure(rig.slide)
            rig.feed.horizontalPermitted = false
            let pan = FakePan()
            pan.fakeVelocity = CGPoint(x: 900, y: 0)

            #expect(rig.hero.gestureRecognizerShouldBegin(pan) == false, "\(arming.name): hero")
            #expect(rig.slide.gestureRecognizerShouldBegin(pan) == false,
                    "\(arming.name): the slide grabbed a drag the screen gave to its carousel")
        }
    }

    /// And the same drag with the tenant out of the way (the carousel's first
    /// photograph, or no carousel at all) still has exactly one driver — the
    /// veto must not become a gap.
    @Test func aDragNoTenantWantsStillHasExactlyOneDriver() {
        for kind in [ZoomDismissalKind.hero, .card] {
            let rig = rig(kind: kind)
            let pan = FakePan()
            pan.fakeVelocity = CGPoint(x: 900, y: 0)

            let claims = [
                rig.hero.gestureRecognizerShouldBegin(pan),
                rig.slide.gestureRecognizerShouldBegin(pan),
            ].filter { $0 }
            #expect(claims.count == 1, "kind \(kind) has \(claims.count) drivers")
        }
    }

    /// ⚠️ BOTH DRIVERS ASK AT THE DRAG'S ORIGIN, not where the finger is by the
    /// time the slop is spent. A drag that began in the leading strip (x=12) is
    /// asked about as x=12 by each — read at the finger (x=52) it is "not the
    /// edge", and a carousel past its first photograph would keep it.
    @Test func everyDriverAsksAtTheDragsOrigin() {
        for kind in [ZoomDismissalKind.hero, .card] {
            let rig = rig(kind: kind)
            let pan = FakePan()
            pan.fakeVelocity = CGPoint(x: 900, y: 0)
            pan.fakeLocation = CGPoint(x: 52, y: 400)
            pan.fakeTranslation = CGPoint(x: 40, y: 3)

            _ = rig.hero.gestureRecognizerShouldBegin(pan)
            _ = rig.slide.gestureRecognizerShouldBegin(pan)

            // The driver that stood down on the kind never reaches the
            // question, so one ask per kind — and at the origin.
            #expect(rig.feed.horizontalAsks == [CGPoint(x: 12, y: 397)], "kind \(kind)")
        }
    }
}
