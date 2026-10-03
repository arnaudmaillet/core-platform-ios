import Testing
import UIKit
@testable import CoreNavigation

/// The terminal branches of the hero push, pinned one defect at a time
/// (`dev/HERO_PUSH_AUDIT_PLAN.md`, Phase 1).
///
/// Most of them are about what a flight leaves behind on a path nobody films:
/// a push caught and dragged back, a close reversed mid-air, a grab whose pop
/// never started. The animator is driven through a fake transition context, so
/// each branch runs headless and synchronously; the property animator is
/// ended with `finishAnimation(at:)`, which runs its completions exactly as
/// UIKit's own finish/cancel does.
@MainActor
struct HeroPushHardeningTests {

    // MARK: - 1.1 The interruptor never drops the touch-up that resumes

    /// A touch-down off-window is ignored (the container outlived the
    /// transition by a beat), but a touch-UP is always honoured: it is the only
    /// thing that resumes a flight a touch-down froze, and dropping it left the
    /// navigation stack mid-transition for good.
    @Test func aFrozenFlightAlwaysHearsItsTouchUp() {
        #expect(ZoomFlightInterruptor.honoursTouch(.began, containerInWindow: true))
        #expect(!ZoomFlightInterruptor.honoursTouch(.began, containerInWindow: false))
        for end in [UIGestureRecognizer.State.ended, .cancelled, .failed] {
            #expect(
                ZoomFlightInterruptor.honoursTouch(end, containerInWindow: false),
                "a touch-up off-window was dropped: the frozen flight never resumes"
            )
        }
    }

    // MARK: - 1.9 One page-rect rule for every leg

    @Test func aPageRectThatIsNotOneFallsBackToTheContainer() {
        let container = CGRect(x: 0, y: 0, width: 402, height: 874)
        let page = CGRect(x: 0, y: 0, width: 402, height: 800)
        #expect(ZoomTransitionGeometry.pageFrame(measured: page, container: container) == page)
        #expect(ZoomTransitionGeometry.pageFrame(measured: nil, container: container) == container)
        #expect(ZoomTransitionGeometry.pageFrame(measured: .zero, container: container) == container)
        let nan = CGRect(x: CGFloat.nan, y: 0, width: 402, height: 874)
        #expect(ZoomTransitionGeometry.pageFrame(measured: nan, container: container) == container)
    }

    // MARK: - F 4.3 A source rect that is not one lands on the fallback

    @Test func aSourceRectThatIsNotOneFallsBackToTheCentre() {
        let container = CGRect(x: 0, y: 0, width: 402, height: 874)
        let fallback = ZoomTransitionGeometry.centeredFallback(in: container)
        let tile = CGRect(x: 20, y: 300, width: 120, height: 160)
        #expect(ZoomTransitionGeometry.sourceFrame(measured: tile, container: container) == tile)
        #expect(ZoomTransitionGeometry.sourceFrame(measured: .zero, container: container) == fallback)
        let nan = CGRect(x: 20, y: CGFloat.nan, width: 120, height: 160)
        #expect(ZoomTransitionGeometry.sourceFrame(measured: nan, container: container) == fallback)
        let infinite = CGRect(x: 20, y: 300, width: CGFloat.infinity, height: 160)
        #expect(ZoomTransitionGeometry.sourceFrame(measured: infinite, container: container) == fallback)
    }

    // MARK: - 1.11 A back chevron asks the landing too

    /// The grabs refuse a hero onto a landing that cannot receive one (a TEXT
    /// row). The chevron's pop asked only the departure, and flew a picture
    /// onto words.
    @Test func aPopOntoALandingThatRefusesAHeroGetsNoFlight() {
        let source = SpySource()
        let feed = SpyFeed()
        let controller = ZoomTransitionController(source: source, destination: feed)
        let nav = UINavigationController(rootViewController: UIViewController())
        source.setZoomSourceHidden(true)

        source.acceptsHero = false
        #expect(controller.navigationController(
            nav, animationControllerFor: .pop, from: feed, to: UIViewController()
        ) == nil, "the chevron flew a hero onto a landing that refuses one")
        #expect(source.isHidden == false, "declining the flight left the source hidden")

        source.acceptsHero = true
        #expect(controller.navigationController(
            nav, animationControllerFor: .pop, from: feed, to: UIViewController()
        ) != nil)
    }

    // MARK: - 1.14 A re-assert does not swallow the displaced flight's news

    /// An owner re-asserts its slide driver on appearance, inside the pop's
    /// `completeTransition` and before `didShow`. The flight it covers must
    /// still hear that it landed: it stays LEASED beneath the driver, and the
    /// hub tells every lease — once each, even though the driver also forwards
    /// to the delegate it captured.
    @Test func aReassertLeavesTheCoveredFlightHearingItsLanding() {
        let nav = UINavigationController(rootViewController: UIViewController())
        let original = DidShowSpy()
        nav.delegate = original
        let slide = InteractiveSlideDismissal()
        slide.install(on: nav)
        #expect(slide.debugSavedDelegate === original)

        let hub = NavigationDelegateHub.of(nav)
        let landingFlight = DidShowSpy()
        hub.lease(landingFlight)
        slide.install(on: nav)
        #expect(nav.leasedDelegate === slide)

        let screen = nav.topViewController!
        hub.navigationController(nav, didShow: screen, animated: true)
        #expect(landingFlight.didShowCount == 1, "the covered flight never heard it landed")
        #expect(original.didShowCount == 1, "a delegate both leased and forwarded to heard it twice")

        // Until it ends its lease, it keeps hearing; after, it does not.
        hub.release(landingFlight)
        hub.navigationController(nav, didShow: screen, animated: true)
        #expect(landingFlight.didShowCount == 1)
        #expect(original.didShowCount == 2)
        withExtendedLifetime(original) {}
    }

    // MARK: - 1.18 The next-turn dock backstop re-asks the stack

    /// A tap inside the backstop's turn re-opens the feed. The queued show
    /// must then find a screen that conceals the dock, and stand down.
    @Test func theDockBackstopStandsDownOverAScreenThatConcealsIt() async {
        let root = UIViewController()
        let nav = UINavigationController(rootViewController: root)
        let tabs = UITabBarController()
        tabs.viewControllers = [nav]
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        window.rootViewController = tabs
        window.isHidden = false
        defer { window.isHidden = true }

        tabs.setTabBarHidden(true, animated: false)
        tabs.showTabBarNativelyNextTurn()
        nav.pushViewController(SpyFeed(), animated: false)   // the re-open, inside the turn
        try? await Task.sleep(nanoseconds: 50_000_000)
        #expect(tabs.isTabBarHidden, "the backstop raised the dock over a feed that conceals it")

        nav.popViewController(animated: false)
        tabs.showTabBarNativelyNextTurn()
        try? await Task.sleep(nanoseconds: 50_000_000)
        #expect(!tabs.isTabBarHidden, "the backstop stood down over a screen that shows the dock")
    }

    // MARK: - 1.8 A grab with no transition disarms

    /// `beginGrab` arms the driver and freezes the pager before UIKit stages
    /// anything. When no transition follows, the release must disarm both, or
    /// the driver refuses every later pan and hijacks the next pop.
    @Test func aGrabWhosePopNeverStartedDisarms() {
        let driver = ZoomDismissInteractionController()
        let feed = SpyFeed()
        let source = SpySource()
        let view = UIView(frame: CGRect(x: 0, y: 0, width: 400, height: 800))
        driver.attach(to: view, source: source, destination: feed) { /* no pop */ }

        driver.beginGrab()
        #expect(driver.isInteracting)
        #expect(feed.scrollEnabled == false)

        driver.releaseGrab(translation: .zero, velocity: .zero, ended: true, in: view)
        #expect(!driver.isInteracting, "a grab that never staged stayed armed")
        #expect(feed.scrollEnabled == true, "the pager stayed frozen")
    }

    // MARK: - Animator terminal branches

    /// 1.13: a push caught and dragged back leaves the destination VISIBLE.
    /// For You reuses its feed, so an alpha left at 0 was inherited by the next
    /// opening that does not fly: a black screen whose controls took taps.
    @Test func aReversedPushLeavesTheDestinationVisible() throws {
        let stage = Stage()
        let animator = ZoomAnimator(isPresenting: true, source: stage.source, destination: stage.feed)
        var reversed = 0
        animator.onPresentationReversed = { reversed += 1 }
        let context = stage.context(presenting: true)

        let flight = try #require(animator.interruptibleAnimator(using: context) as? UIViewPropertyAnimator)
        #expect(stage.feed.contentHidden == true)
        context.wasCancelled = true
        flight.startAnimation()
        flight.stopAnimation(false)
        flight.finishAnimation(at: .start)

        #expect(context.completed == false)
        #expect(reversed == 1)
        #expect(stage.feed.contentHidden == false, "the reused destination was left hidden")
        #expect(stage.source.isHidden == false)
    }

    /// 1.12: a push that cannot stage reports itself reversed, so the owner's
    /// per-flight lock is released, and the destination is told the flight
    /// it was warned about ended.
    @Test func aPushThatCannotStageIsReportedReversed() {
        let stage = Stage()
        let animator = ZoomAnimator(isPresenting: true, source: stage.source, destination: stage.feed)
        var reversed = 0
        animator.onPresentationReversed = { reversed += 1 }
        let context = stage.context(presenting: true, withViews: false)

        _ = animator.interruptibleAnimator(using: context)

        #expect(context.completed == false)
        #expect(reversed == 1, "the owner never heard the push ended: its lock stays set")
        #expect(stage.feed.didEndCalls == 1)
    }

    /// 1.22: a close reversed mid-air leaves the source CONCEALED — the page
    /// is staying, as a cancelled grab already settles it. Revealed, the next
    /// close flew its card home over a visible twin.
    @Test func aReversedCloseKeepsTheSourceConcealed() throws {
        let stage = Stage()
        let animator = ZoomAnimator(isPresenting: false, source: stage.source, destination: stage.feed)
        let context = stage.context(presenting: false)

        let flight = try #require(animator.interruptibleAnimator(using: context) as? UIViewPropertyAnimator)
        #expect(stage.source.isHidden == true, "the tap-back did not assert the concealment")
        context.wasCancelled = true
        flight.startAnimation()
        flight.stopAnimation(false)
        flight.finishAnimation(at: .start)

        #expect(context.completed == false)
        #expect(stage.source.isHidden == true, "the source came back under a page that stayed")
        #expect(stage.feed.contentHidden == false)
    }

    /// 1.7: once a close has LANDED, the frame-0 hide still waiting on its gate
    /// must not fire. Run the gate's window out after a landing and the feed —
    /// reused by For You — must still be visible.
    @Test func aLandedCloseIsNotHiddenByALateFrameZeroGate() async throws {
        let stage = Stage()
        let animator = ZoomAnimator(isPresenting: false, source: stage.source, destination: stage.feed)
        let context = stage.context(presenting: false)

        let flight = try #require(animator.interruptibleAnimator(using: context) as? UIViewPropertyAnimator)
        // Land synchronously, inside the turn that staged the flight, so the
        // gate (a commit, then display ticks) has certainly not run yet.
        flight.startAnimation()
        flight.stopAnimation(false)
        flight.finishAnimation(at: .end)
        #expect(context.completed == true)
        #expect(stage.feed.contentHidden == false)

        // Past the gate's ceiling (0.15s) with ticks to spare.
        try await Task.sleep(nanoseconds: 400_000_000)
        #expect(stage.feed.contentHidden == false, "a late frame-0 gate hid the feed after it landed")
    }
}

// MARK: - Doubles

@MainActor
private final class Stage {
    let source = SpySource()
    let feed = SpyFeed()
    let presenter = UIViewController()
    let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))

    func context(presenting: Bool, withViews: Bool = true) -> FakeTransitionContext {
        let container = UIView(frame: window.bounds)
        window.addSubview(container)
        window.isHidden = false
        presenter.view.frame = window.bounds
        feed.view.frame = window.bounds
        if !presenting { container.addSubview(feed.view) } else { container.addSubview(presenter.view) }
        return FakeTransitionContext(
            container: container,
            from: presenting ? presenter : feed,
            to: presenting ? feed : presenter,
            withViews: withViews
        )
    }
}

@MainActor
private final class SpySource: NSObject, ZoomTransitionSource {
    private(set) var isHidden = false
    var acceptsHero = true
    var zoomLandingAcceptsHero: Bool { acceptsHero }
    func zoomHeroFrame(in container: UICoordinateSpace) -> CGRect {
        CGRect(x: 10, y: 10, width: 80, height: 80)
    }
    var zoomSourceIsOnScreen: Bool { true }
    func makeZoomFlightCard() -> any ZoomFlightCard { SpyCard() }
    func setZoomSourceHidden(_ hidden: Bool) { isHidden = hidden }
}

private final class SpyCard: UIView, ZoomFlightCard {
    var zoomRestingCornerRadius: CGFloat { 10 }
    var zoomRestingChrome: UIView? { nil }
    func setZoomCornerRadius(_ radius: CGFloat) {}
}

private final class SpyFeed: UIViewController, ZoomTransitionDestination {
    private(set) var contentHidden: Bool?
    private(set) var didEndCalls = 0
    private(set) var scrollEnabled: Bool?
    func zoomTargetFrame(in container: UICoordinateSpace) -> CGRect { .zero }
    func zoomFlightChrome() -> UIView? { nil }
    func setZoomContentHidden(_ hidden: Bool) { contentHidden = hidden }
    func zoomTransitionDidEnd() { didEndCalls += 1 }
    var isReadyForInteractiveDismissal: Bool { true }
    func setContentScrollEnabled(_ enabled: Bool) { scrollEnabled = enabled }
}

private final class DidShowSpy: NSObject, UINavigationControllerDelegate {
    private(set) var didShowCount = 0
    func navigationController(
        _ navigationController: UINavigationController,
        didShow viewController: UIViewController, animated: Bool
    ) {
        didShowCount += 1
    }
}

/// Just enough of UIKit's transition context to run an animator's terminal
/// branches: views, frames, and a record of how it completed.
private final class FakeTransitionContext: NSObject, UIViewControllerContextTransitioning {
    let containerView: UIView
    private let from: UIViewController
    private let to: UIViewController
    private let withViews: Bool
    var wasCancelled = false
    private(set) var completed: Bool?

    init(container: UIView, from: UIViewController, to: UIViewController, withViews: Bool) {
        containerView = container
        self.from = from
        self.to = to
        self.withViews = withViews
    }

    var isAnimated: Bool { true }
    var isInteractive: Bool { false }
    var transitionWasCancelled: Bool { wasCancelled }
    var presentationStyle: UIModalPresentationStyle { .none }
    func updateInteractiveTransition(_ percentComplete: CGFloat) {}
    func finishInteractiveTransition() {}
    func cancelInteractiveTransition() { wasCancelled = true }
    func pauseInteractiveTransition() {}
    func completeTransition(_ didComplete: Bool) { completed = didComplete }
    func viewController(forKey key: UITransitionContextViewControllerKey) -> UIViewController? {
        key == .from ? from : to
    }
    func view(forKey key: UITransitionContextViewKey) -> UIView? {
        guard withViews else { return nil }
        return key == .from ? from.view : to.view
    }
    var targetTransform: CGAffineTransform { .identity }
    func initialFrame(for vc: UIViewController) -> CGRect { containerView.bounds }
    func finalFrame(for vc: UIViewController) -> CGRect { containerView.bounds }
}
