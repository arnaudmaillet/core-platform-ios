#if DEBUG
import UIKit

/// A screen's own answers to "am I at rest?", for `ArrivalInvariants`.
///
/// Each fact is something that must hold once a flight has landed on, or
/// returned to, this screen: a transition-scoped flag back down, a lock
/// released, nothing still concealed.
@MainActor
public protocol ArrivalInvariantReporting: UIViewController {
    func arrivalFacts() -> [(name: String, holds: Bool)]
}

/// Checks the screen a hero flight ends on, once it should be at rest
/// (`dev/HERO_PUSH_AUDIT_PLAN.md` 2.15).
///
/// The census (`ZoomDebugCensus`) counts what is alive; it cannot see a screen
/// left at alpha 0, a dock over a feed, a flag never lowered or a dead
/// recognizer, and each of those shipped at least once. This asks the arrival
/// itself, twice:
/// - **settled**, two ticks after the flight ends: the screen is usable;
/// - **rested**, past every ceiling (the 3s landing cover is the longest):
///   nothing the flight made is left at all.
///
/// Off unless a sink is installed (`HeroTransitionAudit`, `-hero-audit`). Each
/// failure is one `[arrival] FAIL` line naming the screen, the path that
/// reached it and the invariant; every check also prints a `PASS`/`FAIL`
/// summary, so a run's denominator is in the log too.
@MainActor
public enum ArrivalInvariants {
    /// Where verdicts go. Nil (the default) turns every check into a no-op.
    public static var sink: ((String) -> Void)?

    /// Past the landing cover's 3s ceiling, with margin.
    static let restedDelay: TimeInterval = 3.3

    /// Schedules both checks for whatever ends up on top of `nav`.
    static func schedule(on nav: UINavigationController?, path: String) {
        guard sink != nil, let nav else { return }
        DispatchQueue.main.async { [weak nav] in
            DispatchQueue.main.async { [weak nav] in
                guard let nav, let arrival = nav.topViewController else { return }
                check(nav, arrival: arrival, path: path, phase: "settled")
                // The rested check is about THIS arrival: if the viewer has
                // moved on by then, it reports a skip rather than judging
                // another screen under this flight's name.
                DispatchQueue.main.asyncAfter(deadline: .now() + restedDelay) { [weak nav, weak arrival] in
                    guard let nav, let arrival else { return }
                    check(nav, arrival: arrival, path: path, phase: "rested")
                }
            }
        }
    }

    private static func check(
        _ nav: UINavigationController, arrival: UIViewController, path: String, phase: String
    ) {
        guard let sink, let screen = nav.topViewController, nav.view.window != nil else { return }
        guard screen === arrival else {
            sink("[arrival] SKIP screen=\(type(of: arrival)) path=\(path) phase=\(phase) (no longer on top)")
            return
        }
        // A newer transition owns the screen now; its own checks will report.
        guard nav.transitionCoordinator == nil else {
            sink("[arrival] SKIP screen=\(type(of: screen)) path=\(path) phase=\(phase) (transition running)")
            return
        }
        var failures: [String] = []
        func require(_ holds: Bool, _ name: String) { if !holds { failures.append(name) } }

        // The screen and everything above it is visible, touchable and unmoved.
        var view: UIView? = screen.view
        while let current = view, current !== nav.view.window {
            let name = String(describing: type(of: current))
            require(current.alpha >= 0.99, "visible.alpha(\(name)=\(current.alpha))")
            require(!current.isHidden, "visible.hidden(\(name))")
            require(current.isUserInteractionEnabled, "interactive(\(name))")
            require(current.transform == .identity, "transform(\(name))")
            view = current.superview
        }

        // Native chrome is UIKit's: never left faded by a flight.
        require(nav.navigationBar.alpha >= 0.99 || nav.isNavigationBarHidden, "navbar.alpha")
        // ⚠️ THE TAB BAR IS UIKIT'S, ANIMATION INCLUDED, and is judged only
        // at REST. Two ticks after a landing UIKit may still be running its own
        // hide or show, and an overlap while it does is acceptable by product
        // rule (2026-10-03): nothing here may push anyone to cut that
        // animation short. Past every ceiling, the bar has to agree with the
        // screen.
        if phase == "rested", let tabs = nav.tabBarController, tabs.selectedViewController === nav {
            require(tabs.isTabBarHidden == !nav.showsAppTabBar(for: screen), "tabbar.matchesScreen")
        }

        // No dismissal pan whose driver is gone, on the screen itself.
        let deadPans = screen.view.gestureRecognizers?
            .compactMap { $0 as? ZoomDismissPan }.filter { $0.driver == nil }.count ?? 0
        require(deadPans == 0, "deadDismissPans=\(deadPans)")

        if phase == "rested" {
            require(ZoomLandingLeftovers.liveCount == 0, "leftovers=\(ZoomLandingLeftovers.liveCount)")
            require(!FlightOrientationLock.isHeld, "orientationLock")
            for key in [ZoomDebugCensus.Key.animator, ZoomDebugCensus.Key.interruptor,
                        ZoomDebugCensus.Key.landingHold, ZoomDebugCensus.Key.landingCover] {
                let count = ZoomDebugCensus.count(key)
                require(count == 0, "\(key)=\(count)")
            }
        }

        if let reporting = screen as? any ArrivalInvariantReporting {
            for fact in reporting.arrivalFacts() { require(fact.holds, fact.name) }
        }

        let head = "[arrival] screen=\(type(of: screen)) path=\(path) phase=\(phase)"
        if failures.isEmpty {
            sink("\(head) PASS")
        } else {
            for failure in failures { sink("[arrival] FAIL screen=\(type(of: screen)) path=\(path) phase=\(phase) check=\(failure)") }
            sink("\(head) FAIL count=\(failures.count)")
        }
    }
}
#endif
