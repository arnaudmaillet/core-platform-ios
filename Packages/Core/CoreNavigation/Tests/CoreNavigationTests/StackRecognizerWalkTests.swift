import Testing
import UIKit
@testable import CoreNavigation

/// ⚠️ ONE POPPER PER SWIPE (#1144): every custom back recognizer on a stack
/// has UIKit's two pops — the edge one and iOS 26's full-content one —
/// required to fail it. This walks each stack's recognizers, as the issue's
/// acceptance asks, for the two custom poppers the app installs: a screen's
/// full-surface slide and a hero grab.
@MainActor
struct StackRecognizerWalkTests {
    /// A stack in a window, so UIKit gives it both of its pops.
    private func stack(root: UIViewController = UIViewController()) -> (UINavigationController, UIWindow) {
        let nav = UINavigationController(rootViewController: root)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        window.rootViewController = nav
        window.isHidden = false
        nav.view.layoutIfNeeded()
        return (nav, window)
    }

    /// Every custom popper on `nav` has both of UIKit's pops waiting on it.
    private func expectEveryPopperSubordinated(on nav: UINavigationController, expecting count: Int) {
        let poppers = NativePopSubordination.customPoppers(in: nav)
        #expect(poppers.count == count, "found \(poppers.map { type(of: $0) })")
        #expect(NativePopSubordination.nativePops(of: nav).count == 2, "a stack without both native pops")
        for popper in poppers {
            #expect(NativePopSubordination.nativePopsWait(for: popper, in: nav),
                    "UIKit's pops do not wait for \(type(of: popper))")
        }
    }

    @Test func aScreensSlideHasBothNativePopsWaitingOnIt() {
        let (nav, window) = stack()
        let screen = UIViewController()
        let slide = InteractiveSlideDismissal()
        slide.attach(to: screen)
        nav.pushViewController(screen, animated: false)
        slide.install(on: nav)
        expectEveryPopperSubordinated(on: nav, expecting: 1)
        withExtendedLifetime((slide, window)) {}
    }

    /// The slide installed on the stack before its pan exists — the order a
    /// screen can take — is subordinated at the attach.
    @Test func aSlideAttachedAfterItsInstallIsSubordinatedToo() {
        let (nav, window) = stack()
        let screen = UIViewController()
        let slide = InteractiveSlideDismissal()
        nav.pushViewController(screen, animated: false)
        slide.install(on: nav)
        slide.attach(to: screen)
        expectEveryPopperSubordinated(on: nav, expecting: 1)
        withExtendedLifetime((slide, window)) {}
    }

    /// A hero grab, and a second one on the same view (the cluster gallery's
    /// split): both are poppers, both are waited on once the feed shows.
    @Test func aHeroGrabHasBothNativePopsWaitingOnIt() {
        let (nav, window) = stack()
        let feed = WalkFeed()
        let controller = ZoomTransitionController(source: WalkSource(), destination: feed)
        controller.attachInteractiveDismissal(to: feed.view, axes: [.horizontal], onDismiss: {})
        controller.attachInteractiveDismissal(
            to: feed.view, axes: [.vertical], armsUpward: false, towards: WalkSource(), onDismiss: {}
        )
        nav.pushViewController(feed, animated: false)
        controller.navigationController(nav, didShow: feed, animated: false)
        expectEveryPopperSubordinated(on: nav, expecting: 2)
        withExtendedLifetime((controller, window)) {}
    }

    /// A grab attached once the feed is already on the stack is waited on
    /// at its attach, with no showing to come.
    @Test func aHeroGrabAttachedOnAShownFeedIsSubordinated() {
        let (nav, window) = stack()
        let feed = WalkFeed()
        let controller = ZoomTransitionController(source: WalkSource(), destination: feed)
        nav.pushViewController(feed, animated: false)
        controller.attachInteractiveDismissal(to: feed.view, axes: [.horizontal], onDismiss: {})
        expectEveryPopperSubordinated(on: nav, expecting: 1)
        withExtendedLifetime((controller, window)) {}
    }

    /// The walk sees a popper nobody subordinated: the check is not
    /// vacuous.
    @Test func aPopperLeftAloneIsSeen() {
        let (nav, window) = stack()
        let screen = UIViewController()
        nav.pushViewController(screen, animated: false)
        let stray = SlideDismissalPan(target: nil, action: nil)
        screen.view.addGestureRecognizer(stray)
        #expect(NativePopSubordination.customPoppers(in: nav).contains { $0 === stray })
        #expect(!NativePopSubordination.nativePopsWait(for: stray, in: nav))
        NativePopSubordination.subordinate(nativePopsOf: nav, to: stray)
        NativePopSubordination.subordinate(nativePopsOf: nav, to: stray)
        #expect(NativePopSubordination.nativePopsWait(for: stray, in: nav), "idempotent")
        withExtendedLifetime(window) {}
    }
}

private final class WalkSource: NSObject, ZoomTransitionSource {
    var zoomFlightCarriesLivePlayer: Bool { false }
    func zoomHeroFrame(in container: UICoordinateSpace) -> CGRect { CGRect(x: 10, y: 10, width: 80, height: 80) }
    var zoomSourceIsOnScreen: Bool { true }
    func makeZoomFlightCard() -> any ZoomFlightCard { WalkCard() }
    func setZoomSourceHidden(_ hidden: Bool) {}
}

private final class WalkCard: UIView, ZoomFlightCard {
    var zoomRestingCornerRadius: CGFloat { 10 }
    var zoomRestingChrome: UIView? { nil }
    func setZoomCornerRadius(_ radius: CGFloat) {}
}

private final class WalkFeed: UIViewController, ZoomTransitionDestination {
    var zoomDismissalKind: ZoomDismissalKind { .hero }
    func zoomTargetFrame(in container: UICoordinateSpace) -> CGRect { .zero }
    func zoomFlightChrome() -> UIView? { nil }
    func setZoomContentHidden(_ hidden: Bool) {}
    func zoomTransitionDidEnd() {}
    var isReadyForInteractiveDismissal: Bool { true }
    func setContentScrollEnabled(_ enabled: Bool) {}
}
