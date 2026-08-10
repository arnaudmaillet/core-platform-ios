import DesignSystem
import UIKit

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
            // The bar lays out on the next pass, and a selector measured mid
            // crossfade reports a width it is on its way out of.
            try? await Task.sleep(nanoseconds: 1_200_000_000)
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
            finding.problems.append("OVERFLOW present: \(overflow.joined(separator: ", "))")
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
        print(String(format: "[header-audit] %@: screenW=%.0f firstSeg=%.0f overflow=%@",
                     surface, window.bounds.width, selector.firstSegmentWidth,
                     overflow.isEmpty ? "NONE" : "PRESENT"))
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

    /// Anything on this bar that is an overflow affordance.
    private func overflowControls(in root: UIView) -> [String] {
        var found: [String] = []
        func walk(_ view: UIView) {
            let name = String(describing: type(of: view))
            let label = view.accessibilityLabel?.lowercased() ?? ""
            if name.contains("Overflow") || name.contains("Ellipsis")
                || (label == "more" && view is UIControl) {
                found.append("\(name)/label=\(view.accessibilityLabel ?? "-")")
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
