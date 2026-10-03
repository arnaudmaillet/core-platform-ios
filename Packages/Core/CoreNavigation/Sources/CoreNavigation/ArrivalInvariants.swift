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

/// The same, for a VIEW a screen hosts: a component reused by many screens
/// (a post grid) states its own facts once, and every host is checked.
@MainActor
public protocol ArrivalInvariantReportingView: UIView {
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

    /// `-bar-dump`: every layer under the bar's platters with what decides how
    /// it composites, model and presentation side by side.
    static func dumpBar(_ bar: UIView, phase: String, sink: (String) -> Void) {
        func walk(_ layer: CALayer, _ depth: Int, _ inPlatter: Bool) {
            let name = layer.delegate.map { String(describing: type(of: $0)) } ?? String(describing: type(of: layer))
            let platter = inPlatter || name.contains("Platter")
            if platter {
                let p = layer.presentation()
                let filters = (layer.filters ?? []).map { String(describing: $0) }.joined(separator: "|")
                var state = ""
                if let view = layer.delegate as? UIView {
                    state += " tam=\(view.tintAdjustmentMode.rawValue)"
                    if let control = view as? UIControl {
                        state += " en=\(control.isEnabled ? "Y" : "N") hl=\(control.isHighlighted ? "Y" : "n") sel=\(control.isSelected ? "Y" : "n")"
                    }
                    if view is UIImageView || view is UIButton {
                        state += " tint=\(view.tintColor.map { String(describing: $0) } ?? "-")"
                    }
                }
                sink(String(format: "[bar-dump] %@ %@%@ op=%.2f pop=%.2f hid=%@ filters=[%@] anims=%@%@",
                            phase, String(repeating: " ", count: depth), name,
                            layer.opacity, p?.opacity ?? -1, layer.isHidden ? "Y" : "n",
                            filters, (layer.animationKeys() ?? []).joined(separator: ","), state))
            }
            for sub in layer.sublayers ?? [] { walk(sub, depth + 1, platter) }
        }
        walk(bar.layer, 0, false)
    }

    /// Views inside `bar` drawn at a partial alpha, by type and value — an
    /// item cross-fade that stopped short. Hidden subtrees are skipped.
    static func halfFadedViews(in bar: UIView) -> [String] {
        var found: [String] = []
        var queue: [UIView] = [bar]
        while let view = queue.popLast() {
            guard !view.isHidden else { continue }
            if view.alpha > 0.01, view.alpha < 0.99 {
                found.append("\(type(of: view))@\(String(format: "%.2f", view.alpha))")
            }
            queue.append(contentsOf: view.subviews)
        }
        return found
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

        // ⚠️ THE NAVIGATION BAR'S ITEMS ARE NOT LEFT HALF-FADED (2.16). UIKit
        // cross-fades a screen's bar items into the next one's inside the
        // bar's glass platters; a push caught and thrown back left that fade
        // frozen at the fraction it reached — the header's buttons dimmed at
        // rest. Read-only: native chrome is UIKit's, this only looks.
        if ProcessInfo.processInfo.arguments.contains("-bar-dump") {
            Self.dumpBar(nav.navigationBar, phase: phase, sink: sink)
        }
        if phase == "rested" {
            let halfFaded = Self.halfFadedViews(in: nav.navigationBar)
            require(halfFaded.isEmpty, "navbar.itemsHalfFaded=\(halfFaded.joined(separator: ","))")
            // ⚠️ AND NO STYLE LENT TO THE SHARED BARS by a screen that is not
            // up (2.16). A full-bleed snap surface lends the stack's bars its
            // style for its visit; any other screen at rest must find them
            // unstyled. A push caught and thrown back once left the feed's dark
            // style on the presenter's header: grey glass, thin icons.
            let lends = (screen as? any ZoomTransitionDestination)?.concealsAppTabBar == true
            if !lends {
                require(nav.navigationBar.overrideUserInterfaceStyle == .unspecified, "navbar.styleLeftByAnotherScreen")
                require(nav.toolbar.overrideUserInterfaceStyle == .unspecified, "toolbar.styleLeftByAnotherScreen")
            }
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
        // Components report at REST only: a landing legitimately holds their
        // scopes open until it settles.
        if phase == "rested" {
            for view in reportingViews(in: screen.view) {
                for fact in view.arrivalFacts() { require(fact.holds, fact.name) }
            }
        }

        func reportingViews(in root: UIView) -> [any ArrivalInvariantReportingView] {
            var found: [any ArrivalInvariantReportingView] = []
            var queue: [UIView] = [root]
            while let view = queue.popLast() {
                if let reporting = view as? any ArrivalInvariantReportingView, !view.isHidden, view.window != nil {
                    found.append(reporting)
                }
                queue.append(contentsOf: view.subviews)
            }
            return found
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
