import Testing
import UIKit
@testable import CoreNavigation

/// One grab-to-dismiss contract on every screen (#1316): the platform's
/// threshold, one owner for the full-surface gesture, a spring at release.
@MainActor
struct UnifiedGrabDismissTests {
    // MARK: - The threshold

    /// Half the way, or a fling — the system back swipe's rule.
    @Test func aDragReleasedShortOfHalfwayStays() {
        #expect(!ZoomTransitionGeometry.shouldCompleteDismissal(progress: 0.45, velocity: 200))
        #expect(ZoomTransitionGeometry.shouldCompleteDismissal(progress: 0.5, velocity: 0))
        #expect(ZoomTransitionGeometry.shouldCompleteDismissal(progress: 0.1, velocity: 1_200))
        #expect(!ZoomTransitionGeometry.shouldCompleteDismissal(progress: 0.3, velocity: -1_200))
    }

    // MARK: - One owner

    private func staged() -> (slide: InteractiveSlideDismissal, nav: UINavigationController, feed: UIViewController) {
        let root = UIViewController()
        let nav = UINavigationController(rootViewController: root)
        let feed = UIViewController()
        let slide = InteractiveSlideDismissal()
        slide.attach(to: feed)
        slide.install(on: nav)
        nav.pushViewController(feed, animated: false)
        return (slide, nav, feed)
    }

    /// ⚠️ THE OWNER'S "THRESHOLD IGNORED": a pop UIKit's own gesture started
    /// got our slide with no driver behind it and played to the end. It is
    /// UIKit's to drive: no custom animator.
    @Test func aPopUIKitsGestureIsDrivingIsLeftToUIKit() {
        let (slide, nav, feed) = staged()
        slide.nativePopIsDriving = { _ in true }
        let animator = slide.navigationController(
            nav, animationControllerFor: .pop, from: feed, to: nav.viewControllers[0]
        )
        #expect(animator == nil, "a native pop was handed an undriven slide")
    }

    /// The back button (no gesture at all) keeps the slide.
    @Test func aBackButtonPopKeepsTheSlide() {
        let (slide, nav, feed) = staged()
        slide.nativePopIsDriving = { _ in false }
        let animator = slide.navigationController(
            nav, animationControllerFor: .pop, from: feed, to: nav.viewControllers[0]
        )
        #expect(animator is TimelineSlidePopAnimator)
    }

    // MARK: - The spring

    /// The release springs from the finger's speed over what is left, with no
    /// overshoot that would bare the screen beneath.
    @Test func theReleaseSpringsFromTheHandsSpeed() {
        let committing = InteractiveSlideDismissal.releaseSpring(progress: 0.6, velocity: 800, span: 400, commit: true)
        #expect(InteractiveSlideDismissal.releaseDamping == 1)
        #expect(abs(committing.initialVelocity.dx - 800 / 160) < 0.001)
        // A cancel launches back against a finger still moving away: none.
        let cancelling = InteractiveSlideDismissal.releaseSpring(progress: 0.3, velocity: 300, span: 400, commit: false)
        #expect(cancelling.initialVelocity.dx == 0)
        // A cancel thrown back toward rest carries that speed home.
        let thrownBack = InteractiveSlideDismissal.releaseSpring(progress: 0.3, velocity: -600, span: 400, commit: false)
        #expect(abs(thrownBack.initialVelocity.dx - 600 / 120) < 0.001)
    }

    /// The slide leg answers UIKit's request for an interruptible animator, so
    /// the percent driver's spring is what plays.
    @Test func theSlideLegIsInterruptible() {
        let animator = TimelineSlidePopAnimator()
        #expect(animator.responds(to: #selector(UIViewControllerAnimatedTransitioning.interruptibleAnimator(using:))))
    }
}
