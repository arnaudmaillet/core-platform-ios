#if DEBUG
import CoreModels
import CoreNavigation
import UIKit

/// Drives deep, cyclical navigation and audits what it leaves behind.
///
/// The failure this exists for is not a crash and not a wrong screen: it is a
/// screen that LOOKS right and no longer answers touches, because a transition
/// left an overlay in the window, or turned interaction off on a view and never
/// turned it back on, or a stack came home with its tab bar still hidden.
/// Scrolling keeps working — the scroll view's own pan is fine — so the surface
/// reads as alive while every tap lands somewhere invisible.
///
/// That is why the audit HIT-TESTS rather than reading flags. A flag says what
/// a view thinks; a hit test says what a finger would actually reach, which is
/// the only question worth asking here.
@MainActor
final class NavigationStressTest {
    /// What one audit found. Empty `problems` is a pass.
    struct Report {
        let cycle: Int
        var problems: [String] = []
        var isClean: Bool { problems.isEmpty }
    }

    private let tabBarController: UITabBarController
    private let router: any Router
    /// Selects a tab, so the harness can start a cycle from each of them
    /// rather than only from whichever one happened to be showing.
    private let selectTab: @MainActor (AppTab) -> Void
    /// Posts to open. Real mock ids, so the destination genuinely loads rather
    /// than short-circuiting on an empty feed.
    private let postIDs = [PostID("post-0000"), PostID("post-0003"), PostID("post-0006")]
    private let profileID = ProfileID("prof-3")

    init(
        tabBarController: UITabBarController,
        router: any Router,
        selectTab: @escaping @MainActor (AppTab) -> Void
    ) {
        self.tabBarController = tabBarController
        self.router = router
        self.selectTab = selectTab
    }

    /// Runs `cycles` round trips and prints an audit after each.
    ///
    /// Sequential and awaited rather than scheduled: the whole point is the
    /// state a COMPLETED trip leaves for the next one, and overlapping trips
    /// would blur which one left what.
    /// Every tab gets the same treatment.
    ///
    /// Each root reaches the feed by a different route and hides the bottom bar
    /// on its own terms, so a leak that only one of them produces is invisible
    /// from any other. The Profile tab in particular is a ROOT profile — the
    /// case whose dismissal rules differ from a pushed one.
    func run(cycles: Int, tabs: [AppTab] = AppTab.allCases) async {
        print("[nav-stress] begin: \(cycles) cycles × \(tabs.count) tabs")
        var failures = 0
        var attempted = 0
        for tab in tabs {
            selectTab(tab)
            await settle(1.2)
            guard activeStack() != nil else {
                print("[nav-stress] \(tab.rawValue): no stack, skipped")
                continue
            }
            for cycle in 1...cycles {
                attempted += 1
                await performCycle(cycle, tab: tab)
                let report = audit(cycle: cycle)
                if report.isClean {
                    print("[nav-stress] \(tab.rawValue) cycle \(cycle): clean")
                } else {
                    failures += 1
                    for problem in report.problems {
                        print("[nav-stress] \(tab.rawValue) cycle \(cycle): PROBLEM \(problem)")
                    }
                }
            }
        }
        print("[nav-stress] done: \(attempted - failures)/\(attempted) clean")
    }

    // MARK: - Driving

    /// Discover → post → author profile → post → all the way home.
    ///
    /// The profile in the middle is the point: it pushes a feed of its own, so
    /// the stack holds two different feed presentations with two different
    /// transition owners before it unwinds.
    private func performCycle(_ cycle: Int, tab: AppTab) async {
        // A real tap first, when the surface offers one: a router push is a
        // PLAIN push, so a harness built only on routes would never run the
        // hero — the transition most likely to leave something behind, and the
        // whole reason this test exists.
        var trail: [String] = ["root"]
        if let selectable = activeStack()?.topViewController as? any DebugItemSelectable,
           selectable.debugSelectFirstItem() {
            await settle(1.6)
            trail.append("tap→\(depth())")
        } else {
            router.route(to: .postStream(postIDs))
            await settle(1.4)
            trail.append("route→\(depth())")
        }
        router.route(to: .profile(profileID, stub: nil))
        await settle(1.6)
        trail.append("profile→\(depth())")
        // …and a tap on the PROFILE, which flies through `presentSnapFeedHero`
        // — a different transition owner from the one above.
        if let profile = activeStack()?.topViewController as? any DebugItemSelectable,
           profile.debugSelectFirstItem() {
            await settle(1.6)
            trail.append("profileTap→\(depth())")
        } else {
            router.route(to: .postStream(Array(postIDs.reversed())))
            await settle(1.4)
            trail.append("route2→\(depth())")
        }
        print("[nav-stress] \(tab.rawValue) cycle \(cycle) path: \(trail.joined(separator: " "))")
        // CONSECUTIVE GRABS on every third cycle — the case a programmatic pop
        // cannot reach. A pop never asks for an interaction controller, so it
        // cannot notice that the screen beneath was left unable to be grabbed;
        // only grabbing twice in a row does.
        if cycle.isMultiple(of: 3) {
            await unwindByGrabbing(tab: tab, trail: &trail)
            return
        }
        // Home in one move on odd cycles, one pop at a time on even ones: a
        // multi-pop skips every intermediate `viewWillAppear`, which is exactly
        // where bar restoration tends to live.
        if cycle.isMultiple(of: 2) {
            while let stack = activeStack(), stack.viewControllers.count > 1 {
                stack.popViewController(animated: true)
                await settle(0.7)
            }
        } else {
            activeStack()?.popToRootViewController(animated: true)
            await settle(1.2)
        }
    }

    /// The current stack depth, so a cycle can show it actually went somewhere
    /// — a harness that quietly did nothing reports "clean" just as loudly.
    private func depth() -> Int { activeStack()?.viewControllers.count ?? 0 }

    /// Unwinds the stack one interactive grab at a time, reporting each.
    ///
    /// The top screen is a hero-pushed feed, grabbed through the transition
    /// that presented it; the one beneath is the profile, grabbed through its
    /// own slide dismissal. That second grab is the whole point — it is the one
    /// that stopped working once the first completed, because the first handed
    /// the stack's delegate back as nil and orphaned the second.
    private func unwindByGrabbing(tab: AppTab, trail: inout [String]) async {
        if let zoom = ZoomTransitionController.debugMostRecent {
            zoom.debugScriptedGrab()
            await settle(2.6)
            trail.append("grab→\(depth())")
        }
        // What actually owns the stack's transitions at this moment. The
        // whole theory of the bug is that the grab above handed this back
        // wrong, so it is worth reading rather than assuming.
        let delegateNow = activeStack()?.delegate
        print("[nav-stress] \(tab.rawValue): delegate after first grab = "
              + "\(delegateNow.map { String(describing: type(of: $0)) } ?? "nil")")
        var guardrail = 0
        while let top = activeStack()?.topViewController as? any DebugInteractivelyDismissible,
              (activeStack()?.viewControllers.count ?? 0) > 1, guardrail < 4 {
            guardrail += 1
            let began = await top.debugDismissInteractively()
            await settle(1.4)
            if !began {
                // The screen may still have gone away — a pop with no driver
                // does that. The finger just was not steering it.
                print("[nav-stress] \(tab.rawValue): grab not interactive, "
                      + "the stack's delegate is not vending a driver")
            }
            trail.append(began ? "grab→\(depth())" : "GRAB-NOT-DRIVEN→\(depth())")
            if !began { break }
        }
        // Anything the grabs could not reach still has to come home, or the
        // audit would blame the next cycle for this one's leftovers.
        if let stack = activeStack(), stack.viewControllers.count > 1 {
            stack.popToRootViewController(animated: true)
            await settle(1.2)
            trail.append("pop→\(depth())")
        }
        print("[nav-stress] \(tab.rawValue) unwind: \(trail.joined(separator: " "))")
    }

    private func activeStack() -> UINavigationController? {
        tabBarController.selectedViewController as? UINavigationController
    }

    private func settle(_ seconds: Double) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    // MARK: - Auditing

    private func audit(cycle: Int) -> Report {
        var report = Report(cycle: cycle)
        guard let stack = activeStack(), let window = tabBarController.view.window else {
            report.problems.append("no active stack or window")
            return report
        }

        if stack.viewControllers.count != 1 {
            report.problems.append("stack did not unwind: depth=\(stack.viewControllers.count)")
        }

        // The bar the viewer navigates with. Hidden here means stranded: there
        // is nothing left on the stack to restore it.
        if tabBarController.isTabBarHidden {
            report.problems.append("tab bar hidden at root")
        }
        if tabBarController.tabBar.alpha < 0.99 {
            report.problems.append("tab bar alpha=\(tabBarController.tabBar.alpha)")
        }
        if !tabBarController.tabBar.isUserInteractionEnabled {
            report.problems.append("tab bar interaction disabled")
        }

        // Interaction, up the chain. One `false` anywhere above a surface makes
        // every tap on it vanish while scrolling continues to work.
        if let root = stack.viewControllers.first {
            if !root.view.isUserInteractionEnabled {
                report.problems.append("root view interaction disabled")
            }
            if root.view.alpha < 0.99 {
                report.problems.append("root view alpha=\(root.view.alpha)")
            }
            if let stale = disabledAncestor(of: root.view) {
                report.problems.append("interaction disabled on ancestor \(type(of: stale))")
            }
        }

        // What a finger would actually reach, at three heights of the content.
        // A leftover transition container is invisible and full-screen, so it
        // answers every one of these and belongs to nobody on the stack.
        for fraction in [0.35, 0.55, 0.75] {
            let point = CGPoint(x: window.bounds.midX, y: window.bounds.height * fraction)
            guard let hit = window.hitTest(point, with: nil) else {
                report.problems.append("nothing hit-testable at y=\(Int(point.y))")
                continue
            }
            if !isOwned(hit, by: stack) {
                report.problems.append(
                    "touch at y=\(Int(point.y)) lands on \(type(of: hit)) outside the stack"
                )
            }
        }

        // The tab bar has to be reachable too — a full-screen leftover would
        // swallow this even with the bar visible.
        let barPoint = CGPoint(x: tabBarController.tabBar.frame.midX,
                               y: tabBarController.tabBar.frame.midY)
        if let hit = window.hitTest(barPoint, with: nil),
           !hit.isDescendant(of: tabBarController.tabBar),
           !isSearchFieldChrome(hit) {
            report.problems.append("tab bar not reachable: \(type(of: hit)) is over it")
        }

        // Anything parked in the window that is not hosting the shell.
        //
        // UIKit puts the root view controller's view inside a `UITransitionView`
        // of its own, so "not the tab bar controller's view" is not the test —
        // that flagged the shell's own host on every cycle. What matters is
        // whether a window subview CONTAINS the shell; one that does not is a
        // container some transition left behind.
        for extra in window.subviews where !tabBarController.view.isDescendant(of: extra) {
            report.problems.append("leftover window subview \(type(of: extra)) frame=\(extra.frame)")
        }
        return report
    }

    /// Whether the hit view belongs to something currently on the stack, as
    /// opposed to a view left behind by a finished transition.
    private func isOwned(_ view: UIView, by stack: UINavigationController) -> Bool {
        for controller in stack.viewControllers where view.isDescendant(of: controller.view) {
            return true
        }
        // The bar and the tab bar are legitimate answers too.
        return view.isDescendant(of: stack.navigationBar)
            || view.isDescendant(of: tabBarController.tabBar)
    }

    /// Whether a view at the bar's centre is the SEARCH TAB's own field.
    ///
    /// On the search tab the bottom bar is a search field — `UISearchTab`
    /// mirrors it there, which is the whole reason a pushed profile hides the
    /// bar on this app. So a `UISearchBarTextField` answering at the bar's
    /// midpoint is the bar's content, not something covering it, and flagging
    /// it made the search tab fail every cycle for being itself.
    private func isSearchFieldChrome(_ view: UIView) -> Bool {
        // A TEXT FIELD, not a `UISearchBar` ancestor — iOS 26 puts the tab
        // bar's search field somewhere that is not inside a `UISearchBar`, so
        // walking up for one found nothing and the search tab failed every
        // cycle for being itself. `UISearchBarTextField` is a `UITextField`,
        // and a text field answering at the bottom bar's centre is only ever
        // this design.
        if view is UITextField { return true }
        var current: UIView? = view
        while let candidate = current {
            if candidate is UISearchBar || candidate is UITextField { return true }
            current = candidate.superview
        }
        return false
    }

    private func disabledAncestor(of view: UIView) -> UIView? {
        var current: UIView? = view.superview
        while let candidate = current {
            if !candidate.isUserInteractionEnabled { return candidate }
            current = candidate.superview
        }
        return nil
    }
}
#endif
