import Foundation

/// WHEN the grid may put the system tab bar back after a screen it pushed
/// goes away.
///
/// The bar is hidden by hand for the length of a post's visit (see the push in
/// `openPost`), so something has to put it back. The obvious place —
/// `viewWillAppear` on the way back — is right for two of the three paths that
/// reach it and wrong for the third, and the third is the common one:
///
/// UIKit runs the incoming screen's `viewWillAppear` when an interactive pop
/// BEGINS, not when it commits. A drag released below the completion threshold
/// therefore left the bar standing over a feed that had sprung back, with
/// nothing to take it away again — `viewWillDisappear` is guarded on being the
/// top view controller and the stack has already been restored by then, and the
/// completed-pop callback correctly never fires for a cancel. The bar simply
/// stayed.
///
/// Split out as a value because three appearance paths reach one line of code
/// and only one of them may act on it immediately — a distinction with no
/// syntax at the call site, and the reason the bug survived review.
///
/// ⚠️ Lives HERE, not beside the grid that first needed it. It was internal to
/// the Feed package, so the profile — which hides the same one bar for the same
/// screen and has the same three appearance paths — could not reach it and
/// asserted its dock unconditionally instead. The consequence was the exact
/// failure the doc above describes, on the other surface: a swipe released
/// below the threshold left the bar standing over a post that had sprung back.
/// A policy two screens must agree on cannot be owned by one of them.
public enum TabBarRevealPolicy {
    public enum Timing: Equatable {
        /// Nothing is animating: a tab switch back, or a non-animated pop.
        /// Safe to reveal outright.
        case immediately
        /// A scrub owns the screen and could still be taken back. Reveal when
        /// the finger lifts and only if it committed: a cancelled drag leaves
        /// the pushed screen on display, and the bar must stay hidden under it.
        ///
        /// Release, not landing. By the time the finger lifts the outcome is
        /// known and the pop's tail is still running, so the bar has something
        /// to arrive alongside; waiting for the completion handler instead puts
        /// it on a screen that has already landed (measured: ~400ms late).
        case whenTransitionCommits
        /// A hero flight is in the air. It drives the opacity on its own clock
        /// — `showTabBar(alpha:)` makes the bar geometrically present and
        /// visually absent so the flight has something to fade in.
        case drivenByFlight
    }

    public static func timing(hasActiveFlight: Bool, isTransitioning: Bool, isInteractive: Bool) -> Timing {
        if hasActiveFlight { return .drivenByFlight }
        // Only a SCRUB can be taken back. A still screen and a button-driven
        // pop both have a known outcome already, and deferring a certainty is
        // what makes the bar arrive on a screen that has finished moving.
        return isTransitioning && isInteractive ? .whenTransitionCommits : .immediately
    }

    /// The completion half of `.whenTransitionCommits`. Trivial by design: the
    /// value of stating it is that the cancel branch is now a case someone has
    /// to delete on purpose rather than one nobody wrote.
    public static func shouldReveal(afterTransitionCancelled cancelled: Bool) -> Bool {
        !cancelled
    }
}
