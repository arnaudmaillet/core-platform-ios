import Foundation
import UIKit

/// # Native chrome is UIKit's
///
/// Product rule (2026-09-28, and it reverses the one before it): the tab bar,
/// its bottom accessory, a navigation controller's toolbar and its items, the
/// navigation bar — every piece of NATIVE chrome — is shown and hidden by
/// UIKit, through UIKit's own API, on UIKit's own animation. Nothing in this
/// app writes their `alpha`, holds them at 0 through a transition, strips an
/// `opacity` animation UIKit put on them, or fades them on a flight's clock.
///
/// The API, and nothing else: `setTabBarHidden(_:animated: true)`
/// (`showTabBarNatively` / `hideTabBarNatively` below),
/// `hidesBottomBarWhenPushed`, `setBottomAccessory(_:animated:)`,
/// `setToolbarHidden(_:animated:)`, `setNavigationBarHidden(_:animated:)`.
///
/// The bar arriving while a close is still in the air is FINE — stability and
/// the platform's own motion matter more than holding it for the landing,
/// which is what the previous rule did by writing the bar's opacity by hand
/// (and what read as the bar arriving late, then all at once). Our OWN views
/// (a map's filter pills, a feed cell's overlay, a flight's card) are not
/// native chrome and keep their own choreography.
///
/// # WHEN the grid may put the bar back
///
/// What this type still decides is the MOMENT, never the manner. The bar is
/// hidden by hand for the length of a post's visit (see the push in
/// `openPost`), so something has to put it back, and the obvious place —
/// `viewWillAppear` on the way back — is a question on two of the paths that
/// reach it:
///
/// - UIKit runs the incoming screen's `viewWillAppear` when an interactive pop
///   BEGINS, not when it commits. A drag released below the completion
///   threshold used to leave the bar standing over a feed that had sprung
///   back, with nothing to take it away again — `viewWillDisappear` is guarded
///   on being the top view controller, and the completed-pop callback
///   correctly never fires for a cancel. So a scrub reveals at its RELEASE,
///   and only if it committed.
/// - ⚠️ A bar un-hidden INSIDE a close of the snap feed that has not been
///   committed by a finger — a button-driven pop, running from `viewWillAppear`
///   — comes back as a state every API reports as shown and nothing draws: a
///   row of empty glass capsules, or a `UITabBar` left `isHidden` for the life
///   of the screen, measured on For You, the map and the place page. The
///   owners therefore show it BEFORE such a pop is triggered (the chevron's
///   `onWillCloseFeed`), outside any transition, where it paints and where UIKit
///   animates it in alongside the return; this policy's `.afterTransition` is
///   only the backstop for a pop nobody announced.
///
/// Split out as a value because three appearance paths reach one line of code
/// and only one of them may act on it immediately — a distinction with no
/// syntax at the call site, and the reason the first bug survived review.
///
/// ⚠️ Lives HERE, not beside the grid that first needed it. It was internal to
/// the Feed package, so the profile — which hides the same one bar for the same
/// screen and has the same appearance paths — could not reach it and asserted
/// its dock unconditionally instead, stranding the bar over a post that had
/// sprung back. A policy two screens must agree on cannot be owned by one of
/// them.
public enum TabBarRevealPolicy {
    public enum Timing: Equatable {
        /// Nothing is animating, or an ordinary button-driven pop: safe to
        /// reveal outright.
        case immediately
        /// A scrub owns the screen and could still be taken back. Reveal when
        /// the finger lifts and only if it committed: a cancelled drag leaves
        /// the pushed screen on display, and the bar must stay hidden under it.
        case whenTransitionCommits
        /// A close of the snap feed that no finger drives is running, and an
        /// un-hide inside it is not drawn (see the type's doc). Reveal once it
        /// is over, and only if it landed. Normally a no-op: the close's owner
        /// showed the bar before triggering the pop.
        case afterTransition
    }

    /// - Parameter returnsFromFullBleed: whether this appearance is the far
    ///   side of a close of a dock-less screen (`isReturningFromDocklessScreen`)
    ///   — or, for a screen that owns a flight, whether one is in the air.
    public static func timing(returnsFromFullBleed: Bool, isTransitioning: Bool, isInteractive: Bool) -> Timing {
        // With nothing moving there is nothing to be out of step with.
        guard isTransitioning else { return .immediately }
        // Only a SCRUB can be taken back.
        if isInteractive { return .whenTransitionCommits }
        // A button-driven pop has a known outcome. Deferring a certainty is
        // what makes the bar arrive on a screen that has finished moving — so
        // only the one pop whose in-flight un-hide does not paint waits.
        return returnsFromFullBleed ? .afterTransition : .immediately
    }

    /// The completion half of `.whenTransitionCommits` and `.afterTransition`.
    /// Trivial by design: the value of stating it is that the cancel branch is
    /// now a case someone has to delete on purpose rather than one nobody
    /// wrote.
    public static func shouldReveal(afterTransitionCancelled cancelled: Bool) -> Bool {
        !cancelled
    }
}

@MainActor
public extension UITabBarController {
    /// Shows the bar through UIKit, on UIKit's own animation. Idempotent, so
    /// the several owners a return has (the close's driver, the screen it
    /// lands on, a backstop) can all ask and only the first one acts.
    ///
    /// ⚠️ NEVER FOLLOWED BY AN ALPHA WRITE — see the rule above.
    func showTabBarNatively() {
        guard isTabBarHidden else { return }
        setTabBarHidden(false, animated: true)
    }

    /// `showTabBarNatively`, one runloop turn later: for a caller running
    /// inside a transition's completion or a `didShow`/`viewDidAppear`, where
    /// UIKit's own end-of-transition bookkeeping was measured to swallow an
    /// un-hide (see `whenCommitted`). A BACKSTOP — the bar is normally up by
    /// then, and this finds nothing to do.
    ///
    /// ⚠️ RE-ASKED WHEN IT RUNS. A turn is long enough for the viewer to tap
    /// again: a tile tap processed inside it re-opens the feed and hides the
    /// bar, and a backstop that still showed it put the dock over the feed it
    /// had just been told to clear. Whether the bar belongs on screen is
    /// answered when the turn comes, by the stack as it is then.
    func showTabBarNativelyNextTurn() {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.selectedStackShowsTabBarAtRest else { return }
            self.showTabBarNatively()
        }
    }

    /// Whether the selected tab's stack, as it stands, wants the bar: at rest
    /// (a transition in flight decides the bar through its own appearance
    /// policy) and topped by a screen that shows it.
    var selectedStackShowsTabBarAtRest: Bool {
        guard let nav = selectedViewController as? UINavigationController else { return true }
        guard nav.transitionCoordinator == nil else { return false }
        return nav.showsAppTabBar(for: nav.topViewController)
    }

    /// Hides the bar through UIKit, on UIKit's own animation. Idempotent.
    func hideTabBarNatively() {
        guard !isTabBarHidden else { return }
        setTabBarHidden(true, animated: true)
    }
}

@MainActor
public extension UINavigationController {
    /// Whether `screen`, on this stack, shows the app's tab bar — what a
    /// close landing on it may give back.
    ///
    /// ⚠️ `concealsAppTabBar`, NOT conformance to `ZoomTransitionDestination`.
    /// Conformance used to be read as "another full-bleed surface is
    /// underneath, whose own mechanic owns the dock"; the place page conforms
    /// without covering anything, so a feed popping onto it left the viewer
    /// on a perfectly ordinary screen with no dock.
    ///
    /// ⚠️ AND UIKIT'S OWN RULE for a pushed screen: a stack with
    /// `hidesBottomBarWhenPushed` anywhere above its root, up to and including
    /// `screen` (a pushed profile sets it), has no dock to give back.
    func showsAppTabBar(for screen: UIViewController?) -> Bool {
        guard let screen else { return false }
        if (screen as? any ZoomTransitionDestination)?.concealsAppTabBar == true { return false }
        guard let index = viewControllers.firstIndex(of: screen) else { return true }
        return !viewControllers[...index].dropFirst().contains { $0.hidesBottomBarWhenPushed }
    }
}

@MainActor
public extension UIViewControllerTransitionCoordinator {
    /// Runs `body` once this transition is COMMITTED — at the release for a
    /// scrub, at the completion otherwise — and never for one that is
    /// cancelled.
    ///
    /// One runloop turn after UIKit's callout rather than inside it: the
    /// interaction-change handler runs inside the driver's
    /// `finishInteractiveTransition()` and the completion inside
    /// `completeTransition`, and a bar un-hidden from inside UIKit's own
    /// end-of-transition bookkeeping was measured never to render (a
    /// `setTabBarHidden(false)` issued inline from a pop's `viewDidAppear`;
    /// one turn later it painted every time).
    ///
    /// The completion leg is also the backstop for a scrub that never reports
    /// a release — a gesture the system cancels outright — so `body` may be
    /// asked twice; it must be idempotent, which every reveal here is.
    func whenCommitted(_ body: @escaping @MainActor () -> Void) {
        if isInteractive {
            notifyWhenInteractionChanges { context in
                guard TabBarRevealPolicy.shouldReveal(afterTransitionCancelled: context.isCancelled)
                else { return }
                DispatchQueue.main.async { body() }
            }
        }
        animate(alongsideTransition: nil) { context in
            guard TabBarRevealPolicy.shouldReveal(afterTransitionCancelled: context.isCancelled)
            else { return }
            DispatchQueue.main.async { body() }
        }
    }

    /// Runs `body` once this transition is OVER and landed — never for one
    /// that is cancelled, and never at the release of a scrub.
    func whenLanded(_ body: @escaping @MainActor () -> Void) {
        animate(alongsideTransition: nil) { context in
            guard TabBarRevealPolicy.shouldReveal(afterTransitionCancelled: context.isCancelled)
            else { return }
            DispatchQueue.main.async { body() }
        }
    }
}

@MainActor
public extension UIViewController {
    /// Whether this screen is appearing because a screen that shows NO dock —
    /// the snap feed (`ZoomTransitionDestination.concealsAppTabBar`) — is
    /// leaving it. Asked of the transition in flight, so it is only true
    /// between a close's begin and its landing.
    var isReturningFromDocklessScreen: Bool {
        guard let from = transitionCoordinator?.viewController(forKey: .from),
              from !== self, from !== navigationController
        else { return false }
        return (from as? any ZoomTransitionDestination)?.concealsAppTabBar == true
    }

    /// Runs `reveal` at the moment `TabBarRevealPolicy` allows for this
    /// screen's transition in flight: now, at a committed release, or after a
    /// landed close. The HOW is the caller's `reveal`, which must go through
    /// UIKit's API (`showTabBarNatively`) and never an alpha.
    ///
    /// - Parameter returnsFromFullBleed: see `TabBarRevealPolicy.timing`.
    ///   Defaults to asking the transition (`isReturningFromDocklessScreen`).
    func revealBottomChromeWhenAllowed(returnsFromFullBleed: Bool? = nil,
                                       animated: Bool = true,
                                       _ reveal: @escaping @MainActor (_ animated: Bool) -> Void) {
        let coordinator = transitionCoordinator
        switch TabBarRevealPolicy.timing(
            returnsFromFullBleed: returnsFromFullBleed ?? isReturningFromDocklessScreen,
            isTransitioning: coordinator != nil,
            isInteractive: coordinator?.isInteractive ?? false
        ) {
        case .immediately:
            reveal(animated)
        case .whenTransitionCommits:
            coordinator?.whenCommitted { reveal(true) }
        case .afterTransition:
            coordinator?.whenLanded { reveal(true) }
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
    /// away again; and a close of the snap feed that no finger drives cannot
    /// un-hide the bar from inside itself. `TabBarRevealPolicy` already draws
    /// exactly this distinction for the tab bar itself, and forking it per
    /// screen is what its own doc warns against.
    ///
    /// ⚠️ **THE BAND FOLLOWS THE BAR.** The accessory is not a subview of the
    /// tab bar, and with the bar hidden it does not leave with it — it moves
    /// down to the screen's foot (`.regular` is "above the bar when it is
    /// visible, OR at the bottom of the tab bar controller's view"). So a close
    /// of the feed whose owner has already shown the bar installs it now,
    /// alongside the return; one whose bar is still down waits for the moment
    /// the bar will come back.
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
    /// - Parameter install: idempotent, and called at most once per path — a
    ///   caller keeps its `viewDidAppear` install as the backstop for the paths
    ///   this deliberately declines. UIKit animates it
    ///   (`setBottomAccessory(_:animated: true)`).
    func installBottomChromeWhenAppearing(hasActiveFlight: Bool = false,
                                          handsOver: Bool = false,
                                          _ install: @escaping @MainActor () -> Void) {
        let coordinator = transitionCoordinator
        switch TabBarRevealPolicy.timing(
            returnsFromFullBleed: hasActiveFlight || isReturningFromDocklessScreen,
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
            coordinator.whenCommitted { install() }
        case .afterTransition:
            // The close's owner showed the bar before the pop: the band rides
            // in with it. Otherwise it waits for the bar's own backstop.
            if tabBarController?.isTabBarHidden == false {
                install()
            } else {
                guard let coordinator else { return install() }
                coordinator.whenLanded { install() }
            }
        }
    }
}

@MainActor
public extension UINavigationController {
    /// Runs `work` now if the stack is at rest, or once the transition running
    /// on it has finished (one turn after its completion, so the stack's own
    /// bookkeeping is done).
    ///
    /// ⚠️ UIKit DROPS a push or pop requested mid-transition, silently. A
    /// route (a deep link, a notification tap) arriving while a hero is in the
    /// air was simply lost — after its caller had already hidden the dock and
    /// installed a dismissal for a screen that never came. Routes wait for the
    /// flight instead.
    func whenAtRest(_ work: @escaping @MainActor () -> Void) {
        guard let coordinator = transitionCoordinator else { return work() }
        coordinator.animate(alongsideTransition: nil) { _ in
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.whenAtRest(work)
            }
        }
    }
}

@MainActor
public extension UINavigationController {
    /// Whether a push or pop of THIS stack is running — not merely any
    /// transition `transitionCoordinator` reports.
    ///
    /// ⚠️ `transitionCoordinator` ALSO ANSWERS FOR THE STACK BEING PRESENTED.
    /// A stack presented modally (`OverSheetFeedHost`, over the sound sheet)
    /// opens its post from the presentation's completion, where the coordinator
    /// of that presentation is still reported. A guard reading "any
    /// coordinator" as "a push is running" refused every post opened from the
    /// sound sheet. Only a transition between screens of this stack counts.
    var isTransitioningItsStack: Bool {
        guard let coordinator = transitionCoordinator else { return false }
        let involved = [coordinator.viewController(forKey: .from), coordinator.viewController(forKey: .to)]
        return involved.contains { screen in
            guard let screen, screen !== self else { return false }
            return screen.navigationController === self || viewControllers.contains(screen)
        }
    }
}
