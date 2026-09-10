import Foundation
import UIKit

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

@MainActor
public extension UIViewController {
    /// Puts a piece of bottom chrome up as EARLY as the transition allows.
    ///
    /// # Why this exists, in one measurement
    ///
    /// The tab bar's accessory band was installed from `viewDidAppear`, and on
    /// a tab switch that is very late. Measured headless (Slow Animations
    /// defeated, or every number here is a lie ×10):
    ///
    ///     +0ms    selectTab messages
    ///     +36ms   inbox viewWillAppear
    ///     +42ms   the OUTGOING screen's band is taken down
    ///     +947ms  inbox viewDidAppear
    ///     +961ms  the incoming band is installed
    ///
    /// Nine hundred milliseconds of empty band under a screen that is fully on
    /// display. The whole of it sits between `viewWillAppear` and
    /// `viewDidAppear`, so moving the install to the earlier one is worth ~900ms
    /// — and, because the incoming screen's `viewWillAppear` lands SIX
    /// MILLISECONDS BEFORE the outgoing screen's `viewWillDisappear`, it also
    /// turns a remove-then-install into a HAND-OVER: the newcomer claims the
    /// slot first, and the screen it replaced finds the band is no longer its
    /// own and leaves it alone. The band never goes away at all between two
    /// screens that both want one.
    ///
    /// ⚠️ **BUT `viewWillAppear` IS A QUESTION, NOT AN ANSWER, ON TWO PATHS** —
    /// which is why this is a policy and not a moved line. UIKit runs it when an
    /// interactive pop BEGINS, so a back-swipe released below the threshold
    /// would show the band over a screen that springs back and then take it
    /// away again; and while a hero flight is in the air the chrome is driven on
    /// the flight's own clock. `TabBarRevealPolicy` already draws exactly this
    /// distinction for the tab bar itself, and forking it per screen is what its
    /// own doc warns against.
    ///
    /// - Parameter hasActiveFlight: whether a hero flight owns the chrome right
    ///   now. Screens without flights pass the default.
    /// - Parameter handsOver: whether a band is ALREADY up, so this is a
    ///   change of contents rather than an arrival.
    ///
    ///   ⚠️ **IT DECIDES WHETHER A SCRUB MAY BE TRUSTED, AND THE REASON IS THE
    ///   FLASH THAT IS NOT THERE.** `.whenTransitionCommits` exists because a
    ///   back-swipe released below the threshold would otherwise show chrome
    ///   over a screen that springs back. That is a real hazard when the chrome
    ///   is arriving from nothing — and no hazard at all when the screen being
    ///   left has a band of its own: something is at the foot either way, and
    ///   deferring only guarantees the gap. Filmed popping the search results
    ///   back to For You: the outgoing band removed at pop-begin and the
    ///   incoming one installed at the release, with empty screen in between.
    ///   A cancelled scrub is covered by the other screen's own
    ///   `viewDidAppear`, which re-claims the slot.
    /// - Parameter install: idempotent, and called at most once — a caller
    ///   keeps its `viewDidAppear` install as the backstop for the paths this
    ///   deliberately declines.
    func installBottomChromeWhenAppearing(hasActiveFlight: Bool = false,
                                          handsOver: Bool = false,
                                          _ install: @escaping () -> Void) {
        let coordinator = transitionCoordinator
        switch TabBarRevealPolicy.timing(
            hasActiveFlight: hasActiveFlight,
            isTransitioning: coordinator != nil,
            isInteractive: coordinator?.isInteractive ?? false
        ) {
        case .immediately:
            // The tab switch — the case this exists for.
            install()
        case .whenTransitionCommits where handsOver:
            // A hand-over, not an arrival: claim the slot now and let the
            // screen being left find it already spoken for.
            install()
        case .whenTransitionCommits:
            guard let coordinator else { return install() }
            coordinator.notifyWhenInteractionChanges { context in
                guard TabBarRevealPolicy.shouldReveal(afterTransitionCancelled: context.isCancelled)
                else { return }
                install()
            }
            // Backstop for a scrub that never reports a release. Idempotent
            // against the notifier above, exactly as the tab bar's own is.
            coordinator.animate(alongsideTransition: nil) { context in
                guard TabBarRevealPolicy.shouldReveal(afterTransitionCancelled: context.isCancelled)
                else { return }
                install()
            }
        case .drivenByFlight:
            // The flight owns the chrome; the caller's `viewDidAppear` install
            // is what puts the band back once it has landed.
            break
        }
    }
}
