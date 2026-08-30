import Testing
import UIKit
@testable import CoreNavigation

/// "Not on the stack" is not "popped" — a feed that has never BEEN on the
/// stack cannot have left it.
///
/// ⚠️ Found by the hero-election suite, not by a screen: `didShow` for an
/// EARLIER, unrelated transition (a gallery pushed `animated:false`, its
/// notification deferred to the next layout pass) can be delivered inside the
/// window where this driver already holds the delegate slot but its feed has
/// not been pushed yet. The old check read the feed's absence as a completed
/// pop: it tore down and fired `onFeedPopped`, whose owner-side closure wipes
/// the flight's retainer — so the `ZoomTransitionController` deallocated
/// before its own push began, and the pushed post arrived with no dismissal
/// grab and the tab bar restored over it. Timing-dependent in production
/// (tap a gallery tile while the gallery's own landing is still delivering),
/// deterministic here.
@MainActor
struct SlidePrematurePopTests {
    private func staged() -> (
        slide: InteractiveSlideDismissal,
        nav: UINavigationController,
        feed: UIViewController,
        root: UIViewController
    ) {
        let root = UIViewController()
        let nav = UINavigationController(rootViewController: root)
        let feed = UIViewController()
        let slide = InteractiveSlideDismissal()
        slide.attach(to: feed)
        slide.install(on: nav)
        return (slide, nav, feed, root)
    }

    /// The regression: a stale `didShow` arriving before the feed's push must
    /// report nothing and keep the delegate slot — the pop it describes
    /// belongs to somebody else's transition.
    @Test func aDidShowBeforeTheFeedsPushIsNotAPop() {
        let (slide, nav, _, root) = staged()
        var popped = 0
        slide.onFeedPopped = { _ in popped += 1 }

        slide.navigationController(nav, didShow: root, animated: false)

        #expect(popped == 0, "an unpushed feed was reported popped")
        #expect(nav.delegate === slide, "the slot was handed back before the feed ever showed")
    }

    /// And the real pop still reports, exactly once: seen on the stack, then
    /// gone, is the only sequence that means anything.
    @Test func aRealPopStillReportsAfterTheFeedWasSeen() {
        let (slide, nav, feed, root) = staged()
        var popped = 0
        slide.onFeedPopped = { _ in popped += 1 }

        // The stale delivery first — the exact production ordering.
        slide.navigationController(nav, didShow: root, animated: false)
        #expect(popped == 0)

        nav.pushViewController(feed, animated: false)
        slide.navigationController(nav, didShow: feed, animated: false)
        #expect(popped == 0, "showing the feed is not popping it")

        nav.popViewController(animated: false)
        slide.navigationController(nav, didShow: root, animated: false)
        #expect(popped == 1, "the completed pop went unreported")

        // Spent: a second stale didShow after teardown reports nothing again.
        slide.navigationController(nav, didShow: root, animated: false)
        #expect(popped == 1)
    }

    /// A fresh presentation of a REUSED driver starts blind again: the
    /// previous life's "seen" must not let a pre-push `didShow` of the next
    /// life read as its pop.
    @Test func aReusedDriverForgetsThePreviousLifesSighting() {
        let (slide, nav, feed, root) = staged()
        var popped = 0
        slide.onFeedPopped = { _ in popped += 1 }

        nav.pushViewController(feed, animated: false)
        slide.navigationController(nav, didShow: feed, animated: false)
        nav.popViewController(animated: false)
        slide.navigationController(nav, didShow: root, animated: false)
        #expect(popped == 1)

        // The next presentation arms the driver again, feed not yet pushed.
        slide.resetForNewPresentation()
        slide.install(on: nav)
        slide.navigationController(nav, didShow: root, animated: false)
        #expect(popped == 1, "the new life's pre-push didShow read as a pop")
    }
}
