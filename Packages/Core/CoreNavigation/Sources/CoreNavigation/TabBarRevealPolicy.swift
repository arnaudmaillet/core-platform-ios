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
/// ## The dock never returns WITH a close — it is there when the close is over
///
/// Product decision, 2026-09-28. Leaving the vertical snap feed for a screen
/// that shows the tab bar — For You, a profile, the place page, the map — the
/// bar used to arrive by as many routes as there were screens: faded in 1:1
/// with a grab, faded in on the flight's spring, slid in alongside a
/// back-button pop, or put back after the landing. Now it is one rule, on
/// every close (hero flight, window, slide, grab, chevron): the bar stays down
/// for the whole return and appears at once at the landing, with no fade. A
/// return that is abandoned never shows it at all.
///
/// Where the grid's LAYOUT depends on the bar, the owner still restores its
/// hidden STATE before the pop (outside any transition, where it paints) at
/// alpha 0 — geometrically present, visually absent — so the landing only
/// flips the opacity and nothing moves.
public enum TabBarRevealPolicy {
    public enum Timing: Equatable {
        /// Nothing is animating: a tab switch back, or a non-animated pop.
        /// Safe to reveal outright.
        case immediately
        /// A scrub owns the screen and could still be taken back. Reveal when
        /// the finger lifts and only if it committed: a cancelled drag leaves
        /// the pushed screen on display, and the bar must stay hidden under it.
        ///
        /// For a scrub that does NOT come back from the snap feed — an ordinary
        /// back-swipe off a pushed screen; the feed's closes are `.atLanding`.
        case whenTransitionCommits
        /// A return from a screen that shows no dock — the snap feed — is in
        /// flight: the bottom chrome is owed at its LANDING, at once, and only
        /// if it lands (see the type's doc).
        case atLanding
    }

    /// - Parameter returnsFromFullBleed: whether this appearance is the far
    ///   side of a close of a dock-less screen (`isReturningFromDocklessScreen`)
    ///   — or, for a screen that owns a flight, whether one is in the air.
    public static func timing(returnsFromFullBleed: Bool, isTransitioning: Bool, isInteractive: Bool) -> Timing {
        // Only a transition HAS a landing to wait for. With nothing moving the
        // landing is now.
        if returnsFromFullBleed, isTransitioning { return .atLanding }
        // Only a SCRUB can be taken back. A still screen and a button-driven
        // pop both have a known outcome already, and deferring a certainty is
        // what makes the bar arrive on a screen that has finished moving.
        return isTransitioning && isInteractive ? .whenTransitionCommits : .immediately
    }

    /// The completion half of `.whenTransitionCommits` and `.atLanding`.
    /// Trivial by design: the value of stating it is that the cancel branch is
    /// now a case someone has to delete on purpose rather than one nobody
    /// wrote.
    public static func shouldReveal(afterTransitionCancelled cancelled: Bool) -> Bool {
        !cancelled
    }
}

@MainActor
public extension UIViewController {
    /// Whether this screen is appearing because a screen that shows NO dock —
    /// the snap feed (`ZoomTransitionDestination.concealsAppTabBar`) — is
    /// leaving it. Asked of the transition in flight, so it is only true
    /// between a close's begin and its landing: exactly the window in which
    /// the dock must not be seen coming back.
    var isReturningFromDocklessScreen: Bool {
        guard let from = transitionCoordinator?.viewController(forKey: .from),
              from !== self, from !== navigationController
        else { return false }
        return (from as? any ZoomTransitionDestination)?.concealsAppTabBar == true
    }

    /// Holds `chrome` at alpha 0 for the rest of the transition in flight.
    ///
    /// ⚠️ FOR A BAR UN-HIDDEN INSIDE A TRANSITION. `setTabBarHidden(false)`
    /// called from `viewWillAppear` of a pop (a tap-back that had no chance to
    /// restore the bar before it began) is finished by UIKit in the
    /// transition's own animation block, which writes the bar's alpha back to
    /// 1 — animated, so it faded in over the return. Measured with
    /// `-dock-trace`: alpha 0 written in `viewWillAppear`, alpha 1 with an
    /// `opacity` animation by the first alongside block. The alongside block
    /// is the one place that runs after UIKit's write and before a frame is
    /// drawn, so the 0 is re-asserted there and UIKit's fade removed.
    func keepInvisibleThroughTransition(_ chrome: UIView?) {
        guard let chrome, let coordinator = transitionCoordinator else { return }
        coordinator.animate(alongsideTransition: { _ in
            chrome.layer.removeAnimation(forKey: "opacity")
            UIView.performWithoutAnimation { chrome.alpha = 0 }
        })
    }

    /// Runs `reveal` at the LANDING of the transition in flight, and only if
    /// it lands — the `.atLanding` half of `TabBarRevealPolicy`. Unanimated:
    /// the dock is simply there when the return is over. With no transition
    /// in flight the landing is now.
    func revealBottomChromeAtLanding(_ reveal: @escaping () -> Void) {
        guard let coordinator = transitionCoordinator else {
            UIView.performWithoutAnimation(reveal)
            return
        }
        coordinator.animate(alongsideTransition: nil) { context in
            guard TabBarRevealPolicy.shouldReveal(afterTransitionCancelled: context.isCancelled)
            else { return }
            UIView.performWithoutAnimation(reveal)
        }
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
    /// away again; and a CLOSE of the snap feed owes its bottom chrome at the
    /// landing, never during the return (`TabBarRevealPolicy.Timing.atLanding`).
    /// `TabBarRevealPolicy` already draws exactly this distinction for the tab
    /// bar itself, and forking it per screen is what its own doc warns against.
    ///
    /// ⚠️ **THE BAND COMES BACK WITH THE BAR, AT THE LANDING.** The accessory is
    /// not a subview of the tab bar (measured with `-dock-trace`: the place
    /// page's pill faded in over a return while the bar stood hidden), so no
    /// alpha written to the bar can hold it back. Returning from the feed, the
    /// install waits for the landing and runs unanimated, which is the moment
    /// and the manner the bar itself is shown.
    ///
    /// - Parameter hasActiveFlight: whether a hero flight owned by this screen
    ///   is in the air. A close of the snap feed is recognised on its own
    ///   (`isReturningFromDocklessScreen`), so screens without flights of their
    ///   own pass the default.
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
    ///   deliberately declines. Its argument says whether to animate: `false`
    ///   at a landing, where the band must appear at once with the bar.
    func installBottomChromeWhenAppearing(hasActiveFlight: Bool = false,
                                          handsOver: Bool = false,
                                          _ install: @escaping (_ animated: Bool) -> Void) {
        let coordinator = transitionCoordinator
        switch TabBarRevealPolicy.timing(
            returnsFromFullBleed: hasActiveFlight || isReturningFromDocklessScreen,
            isTransitioning: coordinator != nil,
            isInteractive: coordinator?.isInteractive ?? false
        ) {
        case .immediately:
            // The tab switch — the case this exists for.
            install(true)
        case .whenTransitionCommits where handsOver:
            // A hand-over, not an arrival: claim the slot now and let the
            // screen being left find it already spoken for.
            install(true)
        case .whenTransitionCommits:
            guard let coordinator else { return install(true) }
            coordinator.notifyWhenInteractionChanges { context in
                guard TabBarRevealPolicy.shouldReveal(afterTransitionCancelled: context.isCancelled)
                else { return }
                install(true)
            }
            // Backstop for a scrub that never reports a release. Idempotent
            // against the notifier above, exactly as the tab bar's own is.
            coordinator.animate(alongsideTransition: nil) { context in
                guard TabBarRevealPolicy.shouldReveal(afterTransitionCancelled: context.isCancelled)
                else { return }
                install(true)
            }
        case .atLanding:
            // With the bar, at once, and only if the close lands. The caller's
            // `viewDidAppear` install stays the backstop and finds the slot
            // already claimed.
            revealBottomChromeAtLanding { install(false) }
        }
    }
}
