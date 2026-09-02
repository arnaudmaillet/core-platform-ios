import DesignSystem
import UIKit

// ⚠️ THE WHOLE FILE, because the whole thing is a DEBUG harness.
//
// It runs only from `-header-audit` / `-header-audit-current`, and both of
// those live inside `MainTabCoordinator`'s own `#if DEBUG`. It also reaches
// for `PagedTabBar.debugSegmentCount`, which is fenced — so compiling this
// for Release asked for a member that does not exist there. Fencing the
// caller is the right side of that: the audit is not product code, and
// publishing a debug affordance to satisfy it would have been.
#if DEBUG

/// `-header-audit` — checks the leading-group selector layout on every surface
/// that wears one.
///
/// Four surfaces host a `PagedTabBar`, and the layout can fail differently on
/// each: the group has to FIT beside the trailing items (a selector that is wide
/// enough on For You may be squeezed on the inbox), it has to take touches (a
/// bar item's custom view with an unresolved size draws perfectly and answers
/// nothing), and on a pushed surface it must not have displaced the back button —
/// which would silently kill the interactive pop.
///
/// Every one of those is invisible in a screenshot, which is why this walks the
/// real view tree and hit-tests real points instead.
@MainActor
final class HeaderSelectorAudit {
    struct Finding {
        let surface: String
        var problems: [String] = []
        var isClean: Bool { problems.isEmpty }
    }

    private let tabBarController: UITabBarController
    private let selectTab: @MainActor (AppTab) -> Void

    init(tabBarController: UITabBarController, selectTab: @escaping @MainActor (AppTab) -> Void) {
        self.tabBarController = tabBarController
        self.selectTab = selectTab
    }

    /// Surfaces that MUST carry a selector. Without this list a vanished
    /// capsule reads as "nothing to audit here" and the run passes — which is
    /// exactly what happened when the inbox's selector was clobbered off the bar.
    private let mustHaveSelector: Set<AppTab> = [.forYou, .messages]

    func run(tabs: [AppTab]) async {
        print("[header-audit] begin: \(tabs.count) surfaces")
        var findings: [Finding] = []
        for tab in tabs {
            selectTab(tab)
            // ⚠️ Waits for a SETTLED frame, exactly as the current-surface mode
            // does. A fixed 1.2s wait reported "NO SELECTOR on a surface that must
            // have one" for a bar that a screenshot showed hosting it perfectly —
            // the page simply had not laid out yet. Only one of the two modes was
            // fixed the first time, and the other went on lying.
            var previous = CGRect.null
            var stable = 0
            for _ in 0..<24 {
                try? await Task.sleep(nanoseconds: 250_000_000)
                let frame = selectorFrameOnScreen
                if frame != .null, frame == previous {
                    stable += 1
                    if stable >= 2 { break }
                } else {
                    stable = 0
                }
                previous = frame
            }
            findings.append(audit(surface: tab.rawValue))
        }
        for finding in findings {
            if finding.isClean {
                print("[header-audit] \(finding.surface): clean")
            } else {
                for problem in finding.problems {
                    print("[header-audit] \(finding.surface): PROBLEM \(problem)")
                }
            }
        }
        let failed = findings.filter { !$0.isClean }
        print("[header-audit] done: \(findings.count - failed.count)/\(findings.count) clean")
    }

    /// The visible selector's frame in its window, or `.null` if there is none —
    /// the value the current-surface mode watches until it stops changing.
    var selectorFrameOnScreen: CGRect {
        guard let nav = topNavigationController,
              let selector = firstPagedTabBar(in: nav.navigationBar),
              let window = selector.window,
              selector.bounds.width > 1
        else { return .null }
        return selector.convert(selector.bounds, to: window)
    }

    /// Whether a selector is on the visible bar yet — what the current-surface
    /// mode waits for, so a slow load is not read as a missing capsule.
    var hasSelectorOnScreen: Bool {
        guard let nav = topNavigationController,
              let selector = firstPagedTabBar(in: nav.navigationBar)
        else { return false }
        return selector.window != nil && selector.bounds.width > 1
    }

    /// Audits whichever navigation bar is currently on screen.
    func audit(surface: String) -> Finding {
        var finding = Finding(surface: surface)
        guard let nav = topNavigationController else {
            finding.problems.append("no navigation controller")
            return finding
        }
        let bar = nav.navigationBar
        // `-header-bar-tree` on the sweep too, not only on the current-surface
        // mode: a bar that fails is read against one that does not, and the
        // comparison is the diagnosis.
        if ProcessInfo.processInfo.arguments.contains("-header-bar-tree") {
            print("[bar-tree] ---- \(surface) ----")
            dumpBarTree()
        }
        guard let selector = firstPagedTabBar(in: bar) else {
            if let tab = AppTab(rawValue: surface), mustHaveSelector.contains(tab) {
                finding.problems.append("NO SELECTOR on a surface that must have one")
                // The inventory, because "it is not on the bar" has several
                // causes that look identical: the item was never added, the
                // item is there but its custom view was never hosted, or
                // something replaced the group after we wrote it.
                let item = nav.topViewController?.navigationItem
                let describe: ([UIBarButtonItem]?) -> String = { items in
                    (items ?? []).map { entry in
                        let custom = entry.customView.map { String(describing: type(of: $0)) } ?? "system"
                        let hosted = entry.customView?.window != nil ? "hosted" : "UNHOSTED"
                        return "\(custom)/\(hosted)/hidden=\(entry.isHidden)"
                    }.joined(separator: ", ")
                }
                print("[header-audit] \(surface) INVENTORY left=[\(describe(item?.leftBarButtonItems))] "
                    + "right=[\(describe(item?.rightBarButtonItems))] "
                    + "titleView=\(item?.titleView.map { String(describing: type(of: $0)) } ?? "nil") "
                    + "search=\(item?.searchController == nil ? "none" : "set") "
                    + "top=\(nav.topViewController.map { String(describing: type(of: $0)) } ?? "nil")")
                // ⚠️ The inventory says the item is THERE and the custom view is
                // not in a window; it does not say what UIKit put on the bar
                // instead. Dumped unconditionally on a surface that must have a
                // selector and does not — the sweep visits five tabs and cannot
                // be re-run against the one that failed, so evidence not taken
                // here is evidence gone.
                dumpBarTree()
            } else {
                print("[header-audit] \(surface): no selector on this bar")
            }
            return finding
        }
        guard let window = bar.window else {
            finding.problems.append("bar has no window")
            return finding
        }
        let item = nav.topViewController?.navigationItem
        let frame = selector.convert(selector.bounds, to: window)

        // 1. WHERE is it? Reported, not assumed. One surface keeps the title
        // slot on purpose (the inbox — see `MessagesInboxViewController`), and an
        // audit that treats the leading group as the only correct answer would
        // fail a deliberate decision while passing a vanished capsule.
        let inTitleSlot = item?.titleView === selector
            || (item?.titleView.map { selector.isDescendant(of: $0) } ?? false)
        let leadingCount = item?.leftBarButtonItems?.count ?? 0
        if !inTitleSlot {
            if leadingCount == 0 {
                finding.problems.append("not in the title slot and no leading items — nowhere")
            }
            if item?.leftItemsSupplementBackButton != true {
                finding.problems.append("leftItemsSupplementBackButton is false — pop gesture at risk")
            }
        }

        // 2. Does it have a real size, and does it fit?
        if frame.width < 1 || frame.height < 1 {
            finding.problems.append(String(format: "zero size %.0fx%.0f — draws nothing, takes nothing",
                                          frame.width, frame.height))
            return finding
        }
        if frame.maxX > window.bounds.width {
            finding.problems.append(String(format: "overflows the window: maxX %.0f > %.0f",
                                          frame.maxX, window.bounds.width))
        }

        // 3. Does it answer touches, at every segment?
        let segments = max(1, selector.debugSegmentCount)
        for index in 0..<segments {
            let x = frame.minX + frame.width * (CGFloat(index) + 0.5) / CGFloat(segments)
            let point = CGPoint(x: x, y: frame.midY)
            let hit = window.hitTest(point, with: nil)
            if hit?.isDescendant(of: selector) != true {
                finding.problems.append(String(format: "segment %d at %.0f,%.0f blocked by %@",
                                              index, point.x, point.y,
                                              hit.map { String(describing: type(of: $0)) } ?? "nil"))
            }
        }

        // 4. THE ABSOLUTE RULE: no overflow control anywhere on this bar. UIKit
        // labels its own "More", so the label is the signal rather than the glyph;
        // a class-name check catches the private container too.
        let overflow = overflowControls(in: bar)
        if !overflow.isEmpty {
            finding.problems.append("COLLAPSED items — \(overflow.joined(separator: ", "))")
        }
        // ⚠️ ONLY THE ITEMS THAT SHARE A PLATTER. `sharesBackground = false` is
        // UIKit's opt-out from the fused pill — the wallet badge takes it, so it
        // draws in a capsule of its OWN and the group's platter legitimately
        // holds one item fewer. Counting it here reported For You's header as a
        // collapsed group while a screenshot showed two capsules side by side:
        // the check was measuring a platter that had never been asked to hold it.
        let trailingCount = (item?.rightBarButtonItems ?? [])
            .count(where: { !$0.isHidden && $0.sharesBackground })
        if let narrow = undersizedTrailingPlatter(in: bar, holding: trailingCount) {
            finding.problems.append(narrow)
        }

        // 5. On a pushed surface, is the back button still there and reachable?
        if nav.viewControllers.count > 1 {
            let backPoint = CGPoint(x: 28, y: frame.midY)
            let hit = window.hitTest(backPoint, with: nil)
            let reachesBar = hit?.isDescendant(of: bar) ?? false
            if !reachesBar {
                finding.problems.append("back button point does not reach the navigation bar")
            }
            if nav.interactivePopGestureRecognizer?.isEnabled != true {
                finding.problems.append("interactive pop gesture is disabled")
            }
        }

        // HOW it is hosted, not just where. A surface whose selector escapes the
        // clamp is a surface that is not in the host the clamp lives in, and the
        // ancestor chain is the only thing that says so.
        var chain: [String] = []
        var node: UIView? = selector.superview
        var depth = 0
        while let current = node, depth < 4 {
            chain.append(String(describing: type(of: current)))
            node = current.superview
            depth += 1
        }
        let inHost = chain.contains { $0.contains("LeadingSelectorHost") }
        print(String(format: "[header-audit] %@: HOSTING inHost=%@ intrinsic=%.0f "
                     + "hostFrame=%.0fx%.0f chain=%@",
                     surface, inHost ? "YES" : "NO",
                     selector.intrinsicContentSize.width,
                     selector.superview?.frame.width ?? -1,
                     selector.superview?.frame.height ?? -1,
                     chain.joined(separator: "←")))
        print(String(format: "[header-audit] %@: screenW=%.0f firstSeg=%.0f platters=%@",
                     surface, window.bounds.width, selector.firstSegmentWidth,
                     overflow.isEmpty ? "no-collapse" : "COLLAPSED"))
        print(String(format: "[header-audit] %@: selector %.0f,%.0f %.0fx%.0f segments=%d "
                     + "leading=%d pushed=%@ placement=%@",
                     surface, frame.minX, frame.minY, frame.width, frame.height,
                     segments, leadingCount,
                     nav.viewControllers.count > 1 ? "yes" : "no",
                     inTitleSlot ? "TITLE-SLOT" : "empty"))
        return finding
    }

    private var topNavigationController: UINavigationController? {
        var candidate = tabBarController.selectedViewController
        if let nav = candidate as? UINavigationController {
            // A nav inside a nav (a pushed profile's own stack) is not a thing
            // here, but a presented one is: audit what the viewer can touch.
            candidate = nav.presentedViewController ?? nav
        }
        if let nav = candidate as? UINavigationController { return nav }
        return candidate?.navigationController
    }

    /// `-header-bar-tree`: the bar's real subview tree. The overflow detector
    /// returned NONE for a bar that was visibly showing a `•••`, so its heuristics
    /// were guesses; this is how the control gets named instead of guessed at.
    func dumpBarTree() {
        guard let bar = topNavigationController?.navigationBar else { return }
        func walk(_ view: UIView, _ depth: Int) {
            let pad = String(repeating: "  ", count: depth)
            print(String(format: "[bar-tree] %@%@ %.0f,%.0f %.0fx%.0f label=%@",
                         pad, String(describing: type(of: view)),
                         view.frame.minX, view.frame.minY,
                         view.frame.width, view.frame.height,
                         view.accessibilityLabel ?? "-"))
            // ⚠️ Deep enough to reach a platter's CONTENT. At 6 the walk stopped
            // on the two nested `AnimationView`s every platter wraps its item in,
            // so a `•••` and a magnifier printed identically — which is how a
            // collapsed bar read as an intact one.
            guard depth < 9 else { return }
            view.subviews.forEach { walk($0, depth + 1) }
        }
        walk(bar, 0)
    }

    /// The trailing platter, when it is too narrow to be holding the items the
    /// navigation item says are there.
    ///
    /// ⚠️ **The zero-width check below misses this one entirely, and it is the
    /// failure the viewer actually reported.** When UIKit collapses a group it
    /// does not always leave an empty platter behind — for the profile's two
    /// trailing actions it replaced the pair with a single 46pt `•••`, a platter
    /// that is present, non-zero, and hit-testable. The audit called that bar
    /// clean while a screenshot showed one dot-dot-dot where two buttons belong.
    ///
    /// Two glyphs share ONE pill and it measures 115pt, so a platter holding `n`
    /// items is at least `44n`. Anything under that is an overflow wearing the
    /// group's place.
    private func undersizedTrailingPlatter(in bar: UIView, holding count: Int) -> String? {
        guard count > 1 else { return nil }
        var platters: [CGRect] = []
        func walk(_ view: UIView) {
            if String(describing: type(of: view)).contains("PlatterView") {
                platters.append(view.frame)
            }
            view.subviews.forEach(walk)
        }
        walk(bar)
        guard let trailing = platters.max(by: { $0.minX < $1.minX }) else { return nil }
        let needed = CGFloat(count) * 44
        guard trailing.width < needed else { return nil }
        return String(format: "COLLAPSED trailing group — %d items in a %.0fpt platter (needs %.0f)",
                      count, trailing.width, needed)
    }

    /// Bar items UIKit has COLLAPSED, reported as zero-width platters.
    ///
    /// ⚠️ This replaced a hunt for the overflow control itself, by class name or an
    /// accessibility label of "More". That found nothing on a bar that was visibly
    /// showing a `•••` — the overflow button is a plain `PlatterView` with no label
    /// — and reported `overflow=NONE` while the whole leading group was collapsed.
    /// A zero-width platter is the symptom that is actually visible in the tree,
    /// and it is what an overflow leaves behind.
    private func overflowControls(in root: UIView) -> [String] {
        var found: [String] = []
        func walk(_ view: UIView) {
            if String(describing: type(of: view)).contains("PlatterView"),
               view.bounds.width < 1 {
                found.append(String(format: "collapsed platter at %.0f", view.frame.minX))
            }
            view.subviews.forEach(walk)
        }
        walk(root)
        return found
    }

    private func firstPagedTabBar(in root: UIView) -> PagedTabBar? {
        if let bar = root as? PagedTabBar { return bar }
        for subview in root.subviews {
            if let found = firstPagedTabBar(in: subview) { return found }
        }
        return nil
    }
}
#endif
