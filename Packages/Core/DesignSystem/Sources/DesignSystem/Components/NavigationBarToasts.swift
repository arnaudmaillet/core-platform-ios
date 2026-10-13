import UIKit

/// Toasts drawn as the top navigation bar's trailing items (#1058) — the
/// default since the owner kept the experiment (2026-10-12). A screen with
/// no visible bar (the full-screen feed, the camera…) still gets the floating
/// overlay; `-toast-overlay` forces the overlay everywhere (QA).
///
/// While a screen's toasts are up, its trailing items are replaced by one bar
/// item per toast — the bar's own Liquid Glass platter is each toast's glass —
/// and come back when the last one leaves. At most `ToastView.maximumStack`
/// at once, newest at the trailing edge.
///
/// ## The bar never collapses into `•••`
///
/// UIKit sweeps a trailing group that does not fit into an overflow menu. So
/// the toasts are sized against the width the leading group leaves
/// (`budget`): the newest takes what it needs up to what is left, and when
/// all of them do not fit, the OLDEST collapse first to their glyph alone — a
/// perfect bubble. A tap on a collapsed one brings it to the front, expanded.
///
/// ## They follow the screen on top
///
/// One per NAVIGATION CONTROLLER: a push or a pop hands the screen that left
/// its own items back and moves the toasts to the bar of the one now on top,
/// once the transition has ended — as the overlay's toasts outlived a pop.
/// Noticed without a navigation delegate (a delegate costs the full-surface
/// back swipe, `nav-delegate-kills-content-pop`): an invisible probe in the
/// screen's view says when that view leaves the window (pushed over or
/// popped) — the bar keeps a popped item's views, so the toasts themselves
/// never leave it.
///
/// ## The toasts' width comes first
///
/// When the toasts would have to collapse or cut their text, the screen's
/// LEADING items step aside for as long as they are up — all but the
/// leftmost, which is often the screen's way out (dismiss, back) and stays
/// (owner, #1058). They come back with the trailing ones.
///
/// ## Bar-item traps it respects
///
/// - Each custom view's FRAME is sized before the item is handed over: the
///   size UIKit reads at hand-over is the frame (`navbar-leading-selector-
///   collapse`).
/// - Fresh items every time, under a stable identifier per toast: a reused
///   item's wrapper drifts in width; a stable identifier lets UIKit keep the
///   slot across hand-overs (`bar-item-wrapper-drift`).
/// - Never re-handed mid-push: items set while the navigation controller
///   transitions land unanimated at its end (`bar-items-during-push`).
@MainActor
final class NavigationBarToasts {
    /// Whether toasts go to the bar at all (off: the overlay everywhere).
    static var isEnabled = !ProcessInfo.processInfo.arguments.contains("-toast-overlay")
    private static let traces = ProcessInfo.processInfo.arguments.contains("-toast-navbar-trace")

    /// One per navigation controller showing toasts.
    private static var shown: [ObjectIdentifier: NavigationBarToasts] = [:]

    private weak var navigation: UINavigationController?
    /// The screen whose bar holds the toasts now — the controller's top one.
    private weak var screen: UIViewController?
    private weak var navigationItem: UINavigationItem?
    private let key: ObjectIdentifier
    /// Oldest first; the last is the front (expanded, at the trailing edge).
    private var toasts: [ToastView] = []
    /// The screen's own trailing items, put back when the last toast leaves.
    private var savedItems: [UIBarButtonItem]?
    /// The items this handed over last — to tell when the screen replaced them.
    private var handedItems: [UIBarButtonItem] = []
    /// The screen's own leading items while all but the first are hidden,
    /// and what was handed instead.
    private var savedLeadingItems: [UIBarButtonItem]?
    private var handedLeadingItems: [UIBarButtonItem] = []
    /// How far the full leading group reaches, measured while it showed.
    private var fullLeadingExtent: CGFloat?
    private var waitsForTransition = false
    /// In the holding screen's view: its leaving the window means a push or
    /// a pop.
    private var probe: ScreenProbe?

    private init(navigation: UINavigationController, screen: UIViewController) {
        self.navigation = navigation
        self.screen = screen
        navigationItem = screen.navigationItem
        key = ObjectIdentifier(navigation)
    }

    /// Shows `content` in `host`'s navigation bar, or returns nil when there
    /// is no visible bar to show it in (the overlay draws it then).
    static func present(_ content: ToastView.Content, from host: UIViewController) -> ToastView? {
        guard isEnabled, let navigation = host.navigationController ?? (host as? UINavigationController),
              !navigation.isNavigationBarHidden, let screen = navigation.topViewController,
              screen.viewIfLoaded?.window != nil else { return nil }
        // The same controller only: an identifier can be reused once its
        // object is gone, and a stale entry would place nothing.
        let known = shown[ObjectIdentifier(navigation)].flatMap { $0.navigation === navigation ? $0 : nil }
        let toasts = known ?? NavigationBarToasts(navigation: navigation, screen: screen)
        shown[toasts.key] = toasts
        return toasts.show(content)
    }

    // MARK: - Showing

    private func show(_ content: ToastView.Content) -> ToastView {
        let existing = toasts.last { $0.content.key == content.key && !$0.isDismissing }
        // One undo slot, wherever the undo is drawn.
        if content.undoable != nil, let pending = ToastView.pendingUndo, pending !== existing {
            pending.dismiss(animated: true)
        }
        if let existing {
            existing.update(to: content)
            bringToFront(existing)
            return existing
        }
        // A failure, or a condition, preempts the plain confirmations — the
        // overlay's rule.
        if content.style == .failure || content.isCondition {
            for toast in toasts where toast.style == .confirmation && toast.undoable == nil && !toast.content.isCondition {
                toast.dismiss(animated: true)
            }
        }
        let toast = ToastView.makeForBar(content)
        toast.onBarLeave = { [weak self] toast in self?.remove(toast) }
        toast.onBarTap = { [weak self] toast in self?.bringToFront(toast) }
        toast.onBarContentChange = { [weak self] _ in self?.place() }
        // Out of the window with its bar: maybe a push or a pop.
        toast.onBarDetached = { [weak self] _ in self?.lookAgain() }
        if content.undoable != nil { ToastView.pendingUndo = toast }
        toasts.append(toast)
        // Past the maximum the oldest leaves (it commits, if it was an undo).
        while toasts.filter({ !$0.isDismissing }).count > ToastView.maximumStack,
              let oldest = toasts.first(where: { !$0.isDismissing }) {
            oldest.dismiss(animated: true)
        }
        place()
        toast.startInBar()
        return toast
    }

    private func remove(_ toast: ToastView) {
        toasts.removeAll { $0 === toast }
        place()
    }

    private func bringToFront(_ toast: ToastView) {
        guard let index = toasts.firstIndex(where: { $0 === toast }), index != toasts.count - 1 else {
            place()
            return
        }
        toasts.append(toasts.remove(at: index))
        place()
    }

    // MARK: - Placing

    /// Hands the bar its items for the toasts up now — or its own items back
    /// when none is.
    private func place() {
        guard let navigation, screen != nil else {
            Self.shown[key] = nil
            return
        }
        // Mid-push or mid-pop: wait for the transition to end, then place
        // once (`bar-items-during-push`).
        if let coordinator = navigation.transitionCoordinator {
            guard !waitsForTransition else { return }
            waitsForTransition = true
            let waited = coordinator.animate(alongsideTransition: nil) { [weak self] _ in
                DispatchQueue.main.async {
                    self?.waitsForTransition = false
                    self?.place()
                }
            }
            if waited { return }
            waitsForTransition = false
        }
        followTop(of: navigation)
        guard let screen, let navigationItem else { return }
        // A screen with no visible bar: nowhere to show them for now; they
        // keep their time, and come back on the next screen with a bar.
        guard !navigation.isNavigationBarHidden else { return }
        let current = navigationItem.rightBarButtonItems ?? []
        // The screen set its own items since (or this is the first toast):
        // those are the ones to put back.
        if savedItems == nil || !current.elementsEqual(handedItems, by: ===) { savedItems = current }
        let live = toasts.filter { !$0.isDismissing }
        guard !live.isEmpty else {
            handBack(animated: true)
            Self.shown[key] = nil
            trace("restored \(navigationItem.rightBarButtonItems?.count ?? 0) items")
            return
        }
        watch(screen)
        let widths = fitLeading(live, in: screen)
        // Newest first: the first right item sits at the trailing edge.
        handedItems = zip(live, widths).reversed().map { toast, width in
            toast.sizeInBar(width: width)
            let item = UIBarButtonItem(customView: toast)
            item.identifier = "toast.\(ObjectIdentifier(toast).hashValue)"
            // Each toast its own bubble.
            item.sharesBackground = false
            return item
        }
        navigationItem.setRightBarButtonItems(handedItems, animated: true)
        trace("placed \(live.count): widths \(widths.map { Int($0) })")
    }

    /// A push or a pop may have happened: once it has ended, the toasts go
    /// to the screen then on top (`place` waits for the transition).
    private func lookAgain() {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.navigation?.topViewController !== self.screen else { return }
            self.place()
        }
    }

    /// Moves the toasts to the screen now on top, handing the one that left
    /// its own items back.
    private func followTop(of navigation: UINavigationController) {
        guard let top = navigation.topViewController, top !== screen else { return }
        handBack(animated: false)
        trace("followed to \(type(of: top))")
        screen = top
        navigationItem = top.navigationItem
    }

    /// The probe in the holding screen's view, moved along with the toasts.
    private func watch(_ screen: UIViewController) {
        guard probe?.superview !== screen.view else { return }
        probe?.removeFromSuperview()
        let probe = ScreenProbe()
        probe.onLeave = { [weak self] in self?.lookAgain() }
        screen.view.addSubview(probe)
        self.probe = probe
    }

    /// The screen's own items back, if they are still ours to replace.
    private func handBack(animated: Bool) {
        guard let navigationItem else { return }
        if let savedItems, (navigationItem.rightBarButtonItems ?? []).elementsEqual(handedItems, by: ===) {
            navigationItem.setRightBarButtonItems(savedItems, animated: animated)
        }
        restoreLeadingItems()
        savedItems = nil
        handedItems = []
        fullLeadingExtent = nil
        probe?.removeFromSuperview()
        probe = nil
    }

    /// The toasts' widths, making room on the LEADING side first: with the
    /// full leading group when everything fits whole, else with all of it
    /// hidden but its first item.
    private func fitLeading(_ live: [ToastView], in screen: UIViewController) -> [CGFloat] {
        guard let navigationItem, let bar = screen.navigationController?.navigationBar else { return [] }
        let current = navigationItem.leftBarButtonItems ?? []
        // The screen set its own leading items since: those are its items.
        if savedLeadingItems != nil, !current.elementsEqual(handedLeadingItems, by: ===) {
            savedLeadingItems = nil
            handedLeadingItems = []
        }
        let extents = leadingExtents(in: bar)
        if savedLeadingItems == nil { fullLeadingExtent = extents.all }
        let full = budget(in: bar, leading: fullLeadingExtent ?? extents.all)
        let whole = live.map(\.barIdealWidth).reduce(0, +) + Self.spacing(live.count)
        let leading = savedLeadingItems ?? current
        guard whole > full, leading.count > 1 else {
            restoreLeadingItems()
            return layout(live, budget: full)
        }
        if savedLeadingItems == nil {
            savedLeadingItems = current
            handedLeadingItems = [current[0]]
            navigationItem.setLeftBarButtonItems(handedLeadingItems, animated: true)
            trace("leading: kept 1 of \(current.count)")
        }
        return layout(live, budget: budget(in: bar, leading: extents.first))
    }

    private func restoreLeadingItems() {
        guard let saved = savedLeadingItems, let navigationItem else { return }
        if (navigationItem.leftBarButtonItems ?? []).elementsEqual(handedLeadingItems, by: ===) {
            navigationItem.setLeftBarButtonItems(saved, animated: true)
        }
        savedLeadingItems = nil
        handedLeadingItems = []
    }

    static func spacing(_ count: Int) -> CGFloat {
        CGFloat(count - 1) * Self.platterGap + CGFloat(count) * Self.platterInset
    }

    /// Each live toast's width, oldest first: the front takes what it needs
    /// up to what is left; the others keep their text while everything fits,
    /// and collapse to a glyph bubble, oldest first, when it does not.
    private func layout(_ live: [ToastView], budget: CGFloat) -> [CGFloat] {
        let fit = Self.fit(ideals: live.map(\.barIdealWidth), budget: budget)
        for (toast, collapsed) in zip(live, fit.collapsed) { toast.isCollapsedInBar = collapsed }
        return fit.widths
    }

    /// The arithmetic of `layout`, oldest first: every toast at its ideal
    /// width while they all fit; else the oldest collapse to a glyph bubble
    /// one by one until the rest fits — never the front, which then takes
    /// what it needs up to what is left (its text cut if it must).
    static func fit(ideals: [CGFloat], budget: CGFloat) -> (widths: [CGFloat], collapsed: [Bool]) {
        guard !ideals.isEmpty else { return ([], []) }
        let bubble = ToastView.Metrics.barHeight
        var room = budget - spacing(ideals.count)
        var widths = ideals
        var collapsed = ideals.map { _ in false }
        for index in ideals.indices.dropLast() where widths.reduce(0, +) > room {
            collapsed[index] = true
            widths[index] = bubble
        }
        room -= widths.dropLast().reduce(0, +)
        widths[widths.count - 1] = max(bubble, min(widths[widths.count - 1], room))
        return (widths, collapsed)
    }

    /// What the trailing group may take: the bar less its margins and what
    /// the leading group (back button, leading items) occupies, with the gap
    /// UIKit keeps between the two groups.
    private func budget(in bar: UINavigationBar, leading: CGFloat) -> CGFloat {
        let margins = 2 * Self.barMargin
        return bar.bounds.width - margins - (leading > 0 ? leading - Self.barMargin + Self.groupGap : 0)
    }

    /// How far into the bar its leading content reaches: the trailing edge of
    /// the rightmost visible control left of the bar's middle, in the bar's
    /// own row (not a large title below it), and not one of the toasts.
    /// How far the leading group reaches — all of it, and its first item.
    private func leadingExtents(in bar: UINavigationBar) -> (all: CGFloat, first: CGFloat) {
        var extent: CGFloat = 0
        var first: (minX: CGFloat, maxX: CGFloat)?
        var stack: [UIView] = [bar]
        while let view = stack.popLast() {
            if view is ToastView { continue }
            stack.append(contentsOf: view.subviews)
            guard view !== bar, !view.isHidden, view.alpha > 0.01, view is UIControl || view is UIImageView else { continue }
            let frame = view.convert(view.bounds, to: bar)
            guard frame.width > 0, frame.width < bar.bounds.width * 0.6, frame.minY < 56,
                  frame.midX < bar.bounds.width * 0.45 else { continue }
            extent = max(extent, frame.maxX)
            if first == nil || frame.minX < first!.minX - 1 { first = (frame.minX, frame.maxX) }
            else if abs(frame.minX - first!.minX) <= 1 { first!.maxX = max(first!.maxX, frame.maxX) }
        }
        return (extent, first?.maxX ?? 0)
    }

    /// Measured iOS 26/27 bar geometry (`navbar-leading-selector-collapse`):
    /// 16 pt margins, ≥ 24 pt between the groups, adjacent platters 12 pt
    /// apart, a platter 8 pt wider than its content.
    private static let barMargin: CGFloat = 16
    private static let groupGap: CGFloat = 24
    private static let platterGap: CGFloat = 12
    private static let platterInset: CGFloat = 8

    private func trace(_ line: @autoclosure () -> String) {
        guard Self.traces else { return }
        print("[toast-navbar] \(line())")
    }
}

/// An invisible, inert view that says when its screen's view leaves the
/// window (`NavigationBarToasts`).
private final class ScreenProbe: UIView {
    var onLeave: (() -> Void)?

    init() {
        super.init(frame: .zero)
        isHidden = true
        isUserInteractionEnabled = false
        isAccessibilityElement = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil, superview != nil { onLeave?() }
    }
}
