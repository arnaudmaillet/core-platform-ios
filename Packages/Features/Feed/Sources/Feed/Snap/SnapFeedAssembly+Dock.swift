import CoreNavigation
import LaunchArguments
import PostGrid
import UIKit

extension SnapFeedAssembly {
    /// Wraps a surface's reveal hooks with the DOCK's own choreography.
    ///
    /// Composed rather than asked of the surface, because the dock belongs to
    /// the navigation shell and not to whichever screen is opening a post — a
    /// profile should no more have to know how the bar is retired than For You
    /// should have to be told where a profile's rows are. Each hook runs both:
    /// the shell's part and the surface's own.
    static func withDockChoreography(
        _ reveal: TextRevealOrigin, on nav: UINavigationController
    ) -> TextRevealOrigin {
        // `replacingChrome`, never a rebuilt `TextRevealOrigin`. This method
        // used to construct one field by field and dropped four of them —
        // `captionTop`, `authorBand`, `makeDismissStandIn` and `setConcealed` —
        // which are exactly the pieces a profile gallery's reveal was missing
        // while For You's, which does not come through here, had them all.
        reveal.replacingChrome(
            presentationDidEnd: { [weak nav] landed in
                // The bar went down through UIKit with the push. A REVERSED
                // opening never showed the page, so the bar goes back to being
                // the grid's — through UIKit again.
                if !landed { Self.restoreTabBar(on: nav) }
                reveal.presentationDidEnd(landed)
            },
            dismissalDidEnd: { [weak nav] committed in
                reveal.dismissalDidEnd(committed)
                // A BACKSTOP for the dock: the release's commit has normally
                // shown it already. A cancelled swipe never raised it.
                guard committed else { return }
                Self.restoreTabBar(on: nav)
            }
        )
    }

    /// Brings the dock back after a flight that hid it.
    ///
    /// ⚠️ Called from EVERY close-out, not just the completed return. A flight
    /// ends three ways and only one is `onSourceReturned`: the push can be caught
    /// and reversed mid-air (`onPresentationCancelled`, where the destination
    /// never showed), and the grab can be released short of the threshold
    /// (`onDismissalCancelled`, where it stays up and the bar must stay down).
    /// Hanging the restore on one of the three is how a viewer ends up on their
    /// profile with no dock and no gesture that brings it back.
    ///
    /// A local closure was the first shape of this and it CRASHED the Swift
    /// frontend — captured into the flight's own callbacks, it segfaulted the
    /// compiler rather than failing to typecheck. A method is not a workaround
    /// here; it is the thing that compiles.
    ///
    /// ⚠️ The refusal below asks `concealsAppTabBar`, NOT conformance. It used
    /// to test `is any ZoomTransitionDestination` and read that as "another
    /// full-bleed surface is underneath, whose own mechanic owns the dock". The
    /// place page conforms without covering anything, so a feed popping onto it
    /// took this early return and left the viewer on a perfectly ordinary
    /// screen with no dock.
    ///
    /// A BACKSTOP that shows the dock once the screen landed on is the one
    /// on top — a completed return, a reversed opening. Through UIKit, one
    /// turn after the callback it is called from (UIKit's own
    /// end-of-transition bookkeeping was measured to swallow an inline
    /// un-hide), and idempotently: the close's commit has normally shown the
    /// bar already, and a tab ROOT asserts its own on the far side of a
    /// committed scrub (`ProfileViewController.revealDock`).
    static func restoreTabBar(on nav: UINavigationController?) {
        #if DEBUG
        // `-grab-log`: the bar's TWO states at the one moment it is supposed
        // to be back. `hidden=false viewHidden=true` is the defect a bar
        // un-hidden inside a transition leaves — a bar every API reports as
        // shown and nothing draws — and it is invisible from anywhere else.
        if LaunchArgument.grabLog.isPassed() {
            print("[pop] restoreTabBar top="
                + (nav?.topViewController.map { String(describing: type(of: $0)) } ?? "nil")
                + " hidden=\(String(describing: nav?.tabBarController?.isTabBarHidden))"
                + " alpha=\(String(describing: nav?.tabBarController?.tabBar.alpha))"
                + " viewHidden=\(String(describing: nav?.tabBarController?.tabBar.isHidden))")
        }
        #endif
        guard let nav, let tabs = nav.tabBarController,
              nav.showsAppTabBar(for: nav.topViewController)
        else { return }
        tabs.showTabBarNativelyNextTurn()
    }
}
