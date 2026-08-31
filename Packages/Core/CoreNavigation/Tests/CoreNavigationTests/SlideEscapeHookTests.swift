import Testing
import UIKit
@testable import CoreNavigation

/// `InteractiveSlideDismissal.onWillBeginPop` — the restaging window the
/// gallery-opened post's horizontal escape stands on: at swipe-begin the hook
/// drops the mid-stack gallery (a plain stack transaction, no transition
/// running yet) and installs the slide driver as the stack's delegate, so the
/// ordinary single pop that follows is slide-animated and lands one screen
/// deeper — on the map.
///
/// Begin-time facts only, per this target's headless-host rule
/// (`InteractivePopToStackTests`): transition completion — including the
/// cancel path's gallery reinsert — is verified in-app, where displays are
/// real.
///
/// ⚠️ `.serialized` is load-bearing: each test pumps the SHARED main run loop.
@Suite(.serialized)
@MainActor
struct SlideEscapeHookTests {
    @Test func theHookRestagesTheStackBeforeThePopConsultsTheDelegate() async {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        let root = UIViewController()
        let gallery = UIViewController()
        let feed = UIViewController()
        let nav = UINavigationController(rootViewController: root)
        window.rootViewController = nav
        window.makeKeyAndVisible()
        nav.setViewControllers([root, gallery, feed], animated: false)
        window.layoutIfNeeded()

        let slide = InteractiveSlideDismissal()
        slide.attach(to: feed, axes: [.horizontal])
        // The production dance: installed once eagerly (captures the stack's
        // pre-push owner and arms the begin gate), then the slot is handed to
        // another delegate — the zoom flight, here a stand-in — and reclaimed
        // per-gesture by the hook.
        slide.install(on: nav)
        let flightStandIn = PassiveDelegate()
        nav.delegate = flightStandIn

        var hookRuns = 0
        var hookAxis: ZoomDismissAxis?
        slide.onWillBeginPop = { [weak slide, weak nav] axis in
            guard let nav else { return }
            hookRuns += 1
            hookAxis = axis
            slide?.install(on: nav)
            var stack = nav.viewControllers
            stack.removeAll { $0 === gallery }
            nav.setViewControllers(stack, animated: false)
        }

        let driven = await slide.debugPerformSwipe(peakProgress: 0.9)

        #expect(hookRuns == 1, "one swipe, one restaging")
        #expect(hookAxis == .horizontal, "the hook is told which axis is restaging")
        #expect(driven,
                "the pop is interactive — proof the hook's install ran BEFORE the pop consulted the delegate")
        #expect(!nav.viewControllers.contains(gallery),
                "the drop is a begin-time stack transaction: committed whether or not the pop settles")
    }

    /// Nothing about the hook may leak into the ordinary case: without one,
    /// a swipe drives the same single pop it always did.
    @Test func withoutAHookTheSwipeIsTheOrdinarySinglePop() async {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        let root = UIViewController()
        let feed = UIViewController()
        let nav = UINavigationController(rootViewController: root)
        window.rootViewController = nav
        window.makeKeyAndVisible()
        nav.setViewControllers([root, feed], animated: false)
        window.layoutIfNeeded()

        let slide = InteractiveSlideDismissal()
        slide.attach(to: feed, axes: [.horizontal])
        slide.install(on: nav)

        let driven = await slide.debugPerformSwipe(peakProgress: 0.9)
        #expect(driven)
    }

    /// The INSERT mirror of the drop above — the semantic-cluster feed's
    /// vertical dismissal into its place page: at begin the hook slides the
    /// page beneath the feed (same plain transaction, nothing transitioning
    /// yet), so the ordinary single pop lands on it. Begin-time facts only,
    /// as ever: the insert is committed here; the cancel path's removal is
    /// transition-completion territory, verified in-app.
    @Test func aVerticalHookCanInsertTheLandingBeneathTheFeed() async {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        let root = UIViewController()
        let feed = UIViewController()
        let place = UIViewController()
        let nav = UINavigationController(rootViewController: root)
        window.rootViewController = nav
        window.makeKeyAndVisible()
        nav.setViewControllers([root, feed], animated: false)
        window.layoutIfNeeded()

        let slide = InteractiveSlideDismissal()
        slide.attach(to: feed, axes: [.horizontal, .vertical])
        slide.install(on: nav)

        slide.onWillBeginPop = { [weak nav, weak feed] axis in
            guard axis == .vertical, let nav, let feed,
                  let feedIndex = nav.viewControllers.firstIndex(of: feed) else { return }
            var stack = nav.viewControllers
            stack.insert(place, at: feedIndex)
            nav.setViewControllers(stack, animated: false)
        }

        let driven = await slide.debugPerformSwipe(peakProgress: 0.9, axis: .vertical)

        #expect(driven, "the vertical swipe drives its pop like the horizontal one")
        #expect(nav.viewControllers.contains(place),
                "the insert is a begin-time stack transaction, beneath the feed before the pop")
    }

    /// A delegate that answers nothing — the stand-in for a zoom flight
    /// holding the slot between gestures.
    @MainActor
    private final class PassiveDelegate: NSObject, UINavigationControllerDelegate {}
}
