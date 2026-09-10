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
    ///
    /// ⚠️ `.profile` IS ON THIS LIST NOW. The viewer's own profile carries a
    /// selector too, and it was left off while the strip lived in the scroll
    /// view — where this audit could never have found it anyway. It is in the
    /// bottom accessory now, which is somewhere the audit looks.
    private let mustHaveSelector: Set<AppTab> = [.forYou, .messages, .profile]

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
            var finding = audit(surface: tab.rawValue)
            if let problem = await collapseProblem(surface: tab.rawValue) {
                finding.problems.append(problem)
            }
            findings.append(finding)
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

    /// Where the visible selector is, and which chrome is carrying it.
    ///
    /// ⚠️ **THREE PLACES NOW, NOT ONE.** A selector used to be a navigation-bar
    /// item and this audit only ever walked `nav.navigationBar`. Selectors are
    /// moving to the tab bar controller's `bottomAccessory` (a screen with the
    /// tab bar under it) and to the navigation controller's bottom TOOLBAR (a
    /// screen without one), so a lookup that reads the bar alone reports "NO
    /// SELECTOR on a surface that must have one" for a screen working exactly
    /// as designed — and, worse, the settle loops below wait out their whole
    /// timeout for a capsule that arrived somewhere else.
    private enum SelectorHost: String {
        case navigationBar = "navigation bar"
        case bottomAccessory = "bottom accessory"
        case bottomToolbar = "bottom toolbar"
        case elsewhere = "somewhere else"
    }

    /// ⚠️ **SEARCHED FROM THE WINDOW DOWN, THEN CLASSIFIED — not looked for
    /// inside each candidate host.** Searching `nav.toolbar` finds nothing for a
    /// strip that is visibly in the bottom toolbar: measured on the search
    /// results and the relationships screen, `toolbarItems` held 3 and 2 items,
    /// `isToolbarHidden` was false, and `nav.toolbar.bounds` came back **375x667**
    /// — the whole screen, which is not a toolbar's geometry. UIKit hosts a
    /// bottom bar item's custom view in its own container, the same way it hosts
    /// an accessory in `_UITabAccessoryContainer` rather than in the tab bar. So
    /// both screens were reported bare while a screenshot showed their strips
    /// hosted perfectly.
    ///
    /// Finding the view first and asking what is ABOVE it needs no knowledge of
    /// UIKit's private containers, and the ancestor chain is printed anyway.
    ///
    /// ⚠️ **AND THE TOOLBAR IS RECOGNISED BY ITS ITEM, NOT BY ITS ANCESTRY.**
    /// The chain above a toolbar-hosted strip has no toolbar in it either:
    ///
    ///     CustomViewWrapper
    ///       ← UICorePlatformViewHost<PlatformViewRepresentableAdaptor<…>>
    ///       ← _UIInheritedView
    ///       ← UIPlatformGlassInteractionView
    ///
    /// iOS 26 draws the bottom bar out of a platform-glass hierarchy that is
    /// not under `UIToolbar` at all, which is the same reason `nav.toolbar`
    /// answers 375x667. So the question asked is the one with an exact answer:
    /// is this view the custom view of one of the screen's own `toolbarItems`?
    private func locateSelector() -> (bar: PagedTabBar, host: SelectorHost)? {
        guard let window = tabBarController.view.window,
              let found = firstPagedTabBar(in: window)
        else { return nil }
        let nav = topNavigationController
        let toolbarHosts = (nav?.topViewController?.toolbarItems ?? []).compactMap(\.customView)
        if toolbarHosts.contains(where: { found === $0 || found.isDescendant(of: $0) }) {
            return (found, .bottomToolbar)
        }
        var node: UIView? = found
        while let current = node {
            if current === nav?.navigationBar { return (found, .navigationBar) }
            if current === tabBarController.bottomAccessory?.contentView {
                return (found, .bottomAccessory)
            }
            let name = String(describing: type(of: current))
            if current === nav?.toolbar || name.contains("Toolbar") {
                return (found, .bottomToolbar)
            }
            if name.contains("TabAccessory") { return (found, .bottomAccessory) }
            node = current.superview
        }
        return (found, .elsewhere)
    }

    /// The visible selector's frame in its window, or `.null` if there is none —
    /// the value the current-surface mode watches until it stops changing.
    var selectorFrameOnScreen: CGRect {
        guard let selector = locateSelector()?.bar,
              let window = selector.window,
              selector.bounds.width > 1
        else { return .null }
        return selector.convert(selector.bounds, to: window)
    }

    /// Whether a selector is on screen yet — what the current-surface mode
    /// waits for, so a slow load is not read as a missing capsule.
    var hasSelectorOnScreen: Bool {
        guard let selector = locateSelector()?.bar else { return false }
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
        let located = locateSelector()
        // ⚠️ **A HOST LABEL, NOT AN EARLY RETURN.** The first cut of this
        // branch printed "selector is in the BOTTOM ACCESSORY" and returned a
        // clean finding — which stopped the audit checking anything at all
        // about a strip that had merely moved. Everything below except the
        // `•••` rule is host-agnostic (a real size, a hit-testable segment, an
        // on-screen frame), so the host is named and the checks continue.
        if let located, located.host != .navigationBar {
            print("[header-audit] \(surface): selector is in the \(located.host.rawValue)")
        }
        guard let selector = located?.bar else {
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
            // ⚠️ WHERE IT LOOKED, ALWAYS. "No selector" has two causes that read
            // identically — the screen has none, or the audit is holding the
            // wrong stack — and it cost two false readings before the second was
            // suspected: the search results and the relationships screen were
            // both reported bare and both photographed the same minute with
            // their strips hosted in the bottom toolbar.
            let presented = tabBarController.selectedViewController?.presentedViewController
            print("[header-audit] \(surface) LOOKED-IN"
                + " tab=\(tabBarController.selectedViewController.map { String(describing: type(of: $0)) } ?? "nil")"
                + " presented=\(presented.map { String(describing: type(of: $0)) } ?? "none")"
                + " stack=[\(nav.viewControllers.map { String(describing: type(of: $0)) }.joined(separator: ","))]"
                + " toolbarHidden=\(nav.isToolbarHidden)"
                + String(format: " toolbar=%.0fx%.0f", nav.toolbar.bounds.width, nav.toolbar.bounds.height)
                + " toolbarItems=\(nav.topViewController?.toolbarItems?.count ?? -1)"
                + " accessory=\(tabBarController.bottomAccessory == nil ? "none" : "set")")
            return finding
        }
        guard let window = bar.window else {
            finding.problems.append("bar has no window")
            return finding
        }
        let item = nav.topViewController?.navigationItem
        let frame = selector.convert(selector.bounds, to: window)

        // 1. WHERE is it? Reported, not assumed — and only asked of a selector
        // that is actually IN the navigation bar. A strip in the bottom
        // accessory or the toolbar is in neither the title slot nor a leading
        // group by design, and judging it against those would fail every
        // screen this audit is being taught about.
        //
        // ⚠️ THE NOTE HERE NAMED THE WRONG SURFACE. It said the inbox keeps the
        // title slot on purpose; the inbox moved its selector to the leading
        // group, and the title-slot host is
        // `ProfileRelationshipsViewController`. A comment naming the wrong
        // screen is worse than none — it is the one a reader trusts.
        let inTitleSlot = item?.titleView === selector
            || (item?.titleView.map { selector.isDescendant(of: $0) } ?? false)
        let leadingCount = item?.leftBarButtonItems?.count ?? 0
        if located?.host == .navigationBar {
            if !inTitleSlot {
                if leadingCount == 0 {
                    finding.problems.append("not in the title slot and no leading items — nowhere")
                }
                if item?.leftItemsSupplementBackButton != true {
                    finding.problems.append("leftItemsSupplementBackButton is false — pop gesture at risk")
                }
            }
        }

        // 2. A BAR ITEM'S custom view has to state a width.
        //
        // ⚠️ Only a bar item. An accessory host pins the strip with constraints
        // and WANTS it to fill, so `noIntrinsicMetric` is correct there. In a
        // navigation bar or a toolbar there is no host width to take, and UIKit
        // falls back to the view's own frame — measured on the pushed profile,
        // a 38x38 bubble holding three segments whose first one wants 71. Every
        // other check on this list passed it as clean.
        if located?.host != .bottomAccessory,
           selector.intrinsicContentSize.width == UIView.noIntrinsicMetric {
            finding.problems.append(
                "hosted as a BAR ITEM with no intrinsic width — it will be sized "
                + "at its own frame (fillsWidth left on?)")
        }

        // 3. Does it have a real size, and does it fit?
        if frame.width < 1 || frame.height < 1 {
            finding.problems.append(String(format: "zero size %.0fx%.0f — draws nothing, takes nothing",
                                          frame.width, frame.height))
            return finding
        }
        if frame.maxX > window.bounds.width {
            finding.problems.append(String(format: "overflows the window: maxX %.0f > %.0f",
                                          frame.maxX, window.bounds.width))
        }

        // 4. Does it answer touches, at every segment?
        //
        // ⚠️ **EACH SEGMENT'S REAL FRAME, NOT THE BAR DIVIDED BY `count`.** The
        // old probe hit `frame.width * (i + 0.5) / count`, which is only the
        // centre of segment `i` while every segment is the same width. A
        // collapsed accessory hands out NATURAL widths — "All" narrower than
        // "Suggestions" — and those points then land off the outer segments and
        // report a working strip as blocked.
        // ⚠️ **AND ONLY THE SEGMENTS THAT ARE ON SCREEN.** The strip is a scroll
        // view: a crowded one keeps every title whole and scrolls the rest out
        // of sight, which is the design, not a fault. The profile's five
        // segments overrun their 325pt slot at 375pt, so segment 4's centre
        // sits at x=352 against a strip that ends at 350 — hit-testing it finds
        // the host, and the old probe only avoided reporting that because it
        // was not testing segment centres at all: it divided the bar by `count`,
        // which lands inside the strip however far the content overflows.
        let segmentFrames = selector.debugSegmentFrames
        var scrolledOut = 0
        for (index, segment) in segmentFrames.enumerated() {
            let centre = selector.convert(CGPoint(x: segment.midX, y: segment.midY), to: window)
            guard frame.insetBy(dx: 1, dy: 1).contains(centre) else {
                scrolledOut += 1
                continue
            }
            let hit = window.hitTest(centre, with: nil)
            if hit?.isDescendant(of: selector) != true {
                finding.problems.append(String(format: "segment %d at %.0f,%.0f blocked by %@",
                                              index, centre.x, centre.y,
                                              hit.map { String(describing: type(of: $0)) } ?? "nil"))
            }
        }
        if scrolledOut > 0 {
            print("[header-audit] \(surface): \(scrolledOut) of \(segmentFrames.count) "
                + "segments scrolled out of the strip — crowded, by design")
        }
        let segments = max(1, selector.debugSegmentCount)

        // 5. THE ABSOLUTE RULE: no overflow control anywhere on this bar. UIKit
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

        // 6. On a pushed surface, is the back button still there and reachable?
        //
        // ⚠️ **AT THE NAVIGATION BAR'S OWN MIDLINE, NOT THE SELECTOR'S.** This
        // probed `frame.midY` — the selector's — which was the same line while
        // the selector lived in the bar. It does not any more: on the place
        // page the strip is at y=532 in a bottom accessory, so the probe
        // hit-tested the tab bar band and reported "back button point does not
        // reach the navigation bar" for a page whose chevron is exactly where
        // it belongs.
        if nav.viewControllers.count > 1 {
            let barFrame = bar.convert(bar.bounds, to: window)
            let backPoint = CGPoint(x: 28, y: barFrame.midY)
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
        // ⚠️ THE `inHost=` FLAG IS GONE WITH THE CLASS IT LOOKED FOR. It asked
        // whether the strip was inside `LeadingSelectorHost`, which no longer
        // exists — every selector is in an accessory or a toolbar now, so the
        // answer was NO everywhere and read as a finding. The CHAIN is still
        // printed, and it is what actually says where a strip ended up.
        print(String(format: "[header-audit] %@: HOSTING intrinsic=%.0f "
                     + "hostFrame=%.0fx%.0f chain=%@",
                     surface,
                     selector.intrinsicContentSize.width,
                     selector.superview?.frame.width ?? -1,
                     selector.superview?.frame.height ?? -1,
                     chain.joined(separator: "←")))
        print(String(format: "[header-audit] %@: screenW=%.0f firstSeg=%.0f platters=%@",
                     surface, window.bounds.width, selector.firstSegmentWidth,
                     overflow.isEmpty ? "no-collapse" : "COLLAPSED"))
        print(String(format: "[header-audit] %@: selector %.0f,%.0f %.0fx%.0f segments=%d "
                     + "leading=%d pushed=%@ host=%@ placement=%@",
                     surface, frame.minX, frame.minY, frame.width, frame.height,
                     segments, leadingCount,
                     nav.viewControllers.count > 1 ? "yes" : "no",
                     located?.host.rawValue ?? "none",
                     inTitleSlot ? "TITLE-SLOT" : "leading-or-elsewhere"))
        return finding
    }

    private var topNavigationController: UINavigationController? {
        var candidate = tabBarController.selectedViewController
        if let nav = candidate as? UINavigationController {
            // A nav inside a nav (a pushed profile's own stack) is not a thing
            // here, but a presented one is: audit what the viewer can touch.
            //
            // ⚠️ **ONLY WHEN THE PRESENTED THING IS A STACK.** It used to take
            // `presentedViewController` whatever it was, and the simulator's
            // camera-permission alert is a `UIAlertController` — which has no
            // navigation controller, so the audit lost the stack underneath and
            // reported "no selector on this bar" for the search results and the
            // relationships screen. Both were photographed the same minute with
            // their strips hosted perfectly in the bottom toolbar. An alert is
            // not the screen under audit; it is something on top of it.
            candidate = (nav.presentedViewController as? UINavigationController) ?? nav
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

    /// The two prerequisites of the collapse, both of which fail SILENTLY.
    ///
    ///   1. `tabBarMinimizeBehavior` has to be armed. It is SHELL-WIDE, so it
    ///      is opt-in per screen — and a screen that forgets looks perfect
    ///      standing still.
    ///   2. The screen has to have NAMED its scroll view, and named the page
    ///      that is actually in front. UIKit's own heuristic does not find one
    ///      nested in a horizontal pager, and naming page 0 while the viewer
    ///      reads page 1 is indistinguishable from naming none: the offset
    ///      never moves, so the band never moves.
    ///
    /// ⚠️ **IT DOES NOT TRY TO PROVE THE COLLAPSE, AND THAT IS DELIBERATE.**
    /// The first version scrolled the registered scroll view with
    /// `setContentOffset` and read the band afterwards. Measured on all three
    /// accessory surfaces, For You included — the one already confirmed
    /// collapsing on a real iPhone:
    ///
    ///     env=regular accessory=360 barH=83 → env=regular accessory=360 barH=83
    ///
    /// UIKit drives the minimize off a DRAG, so a scripted scroll reports three
    /// working screens as broken. The proof lives in
    /// `AccessoryCollapseUITests`, which has a real finger. (`tabBar.frame` is
    /// no use either: 402x83 minimized and 402x83 not.)
    private func collapseProblem(surface: String) async -> String? {
        guard locateSelector()?.host == .bottomAccessory else { return nil }
        guard let top = topNavigationController?.topViewController,
              tabBarController.bottomAccessory?.contentView.window != nil
        else { return "accessory selector but no accessory in a window" }

        if tabBarController.tabBarMinimizeBehavior != .onScrollDown {
            return "minimize NOT ARMED (behavior=\(tabBarController.tabBarMinimizeBehavior.rawValue))"
        }
        guard let named = top.contentScrollView(for: .bottom) else {
            return "no content scroll view registered for .bottom — the band has nothing to ride"
        }
        if let onScreen = OnScreenScroller.candidate(in: top.view), named !== onScreen {
            return "registered the WRONG scroller: \(type(of: named)) at "
                + String(format: "%.0f", named.convert(named.bounds, to: nil).minX)
                + " while the visible page is \(type(of: onScreen)) at "
                + String(format: "%.0f", onScreen.convert(onScreen.bounds, to: nil).minX)
        }
        print("[header-audit] \(surface): collapse armed, riding \(type(of: named))")
        return nil
    }

    private func firstPagedTabBar(in root: UIView) -> PagedTabBar? {
        // Visible ones only: a strip mid-teardown, or one belonging to a screen
        // the viewer has left, is not what is being audited.
        if let bar = root as? PagedTabBar, !bar.isHidden, bar.alpha > 0.01 { return bar }
        if root.isHidden || root.alpha < 0.01 { return nil }
        for subview in root.subviews {
            if let found = firstPagedTabBar(in: subview) { return found }
        }
        return nil
    }
}
#endif
