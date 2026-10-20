import UIKit

/// Taps inside a bar's area reach nothing behind it (#562).
///
/// Content runs edge to edge under the floating tab bar, its accessory, the
/// transparent navigation bars and the bottom toolbars. Those bars answer
/// hit-testing only on their items: a touch beside the tab capsule, in the nav
/// bar band off its buttons, or beside a toolbar platter fell through to the
/// cell, button or map marker underneath, and triggered it.
///
/// One guard for the whole app rather than one per screen, and it only takes
/// TAPS and LONG PRESSES: a finger that starts in a bar's area and moves still
/// scrolls the content under it. `BarTouchGuard` says whether a touch starts
/// over a screen's CONTENT inside one of that screen's visible bars;
/// `BarTapShield`, a gesture recogniser on every window (`AppWindow`), follows
/// such a touch and swallows it only if it ends without moving (a tap) or
/// rests long enough to be a long press. Bar items, their glass and the tab
/// bar's own overlays are never content, so they are never followed.
///
/// ## Nothing to remember (#1145)
///
/// The owner's rule: every screen, a new one included, keeps the content
/// behind its bars from taking taps, with nothing to do when it is made.
/// - **Every window** is an `AppWindow`, which installs the shield. A window
///   made any other way fails `AppWindowGuardTests`.
/// - **Native bars** — navigation bars, bottom toolbars, the tab bar and its
///   accessory — are found by walking the responder chain from the hit view.
/// - **A screen's own floating bar**, which UIKit does not know, is declared
///   once (`declareBar(_:items:)`) and guarded like a native one.
/// - **The left edge too.** It used to be left alone for the edge swipes, but
///   a swipe is never the shield's: it fails as soon as the finger moves past
///   `slop`, so the drawer's edge pan and the back swipe start as before.
///
/// The one exception is VoiceOver: it activates elements without a finger
/// on screen.
public enum BarTouchGuard {
    /// The bar that should take a touch at `point` (window coordinates)
    /// instead of `hit`, or nil to deliver it as hit-tested.
    @MainActor
    public static func bar(replacing hit: UIView, at point: CGPoint, in window: UIWindow) -> UIView? {
        if let declared = declaredBar(replacing: hit, at: point, in: window) { return declared }
        var responder: UIResponder? = hit
        while let current = responder {
            if let navigation = current as? UINavigationController,
               let bar = navigationBar(of: navigation, covering: point, over: hit, in: window) {
                return bar
            }
            if let tabs = current as? UITabBarController,
               let bar = tabBar(of: tabs, covering: point, over: hit, in: window) {
                return bar
            }
            responder = current.next
        }
        return nil
    }

    @MainActor
    private static func navigationBar(
        of navigation: UINavigationController, covering point: CGPoint, over hit: UIView, in window: UIWindow
    ) -> UIView? {
        // Only the content of the screen on top: a nav bar's own glass and
        // items (which can live outside the bar's view tree) are not content.
        guard let content = navigation.topViewController?.viewIfLoaded, hit.isDescendant(of: content) else { return nil }
        if !navigation.isNavigationBarHidden, covers(navigation.navigationBar, point, in: window) {
            return navigation.navigationBar
        }
        if let band = toolbarBand(of: navigation, content: content, in: window), band.contains(point) {
            return navigation.toolbar
        }
        return nil
    }

    /// The bottom toolbar's band, in window coordinates: full width, as tall
    /// as its items stand.
    ///
    /// ⚠️ **NOT `toolbar.frame`.** On iOS 27 the `UIToolbar` view spans the
    /// whole screen (its glass platters live elsewhere), so its frame would
    /// make every tap a "toolbar" tap. Nor the content's safe area: a
    /// full-bleed screen (the snap feed) does not take the toolbar's height
    /// there. What is on screen is the items themselves, so the band runs
    /// from their top to their bottom, plus a little slack.
    @MainActor
    public static func toolbarBand(of navigation: UINavigationController, content: UIView, in window: UIWindow) -> CGRect? {
        // The items' window, not the toolbar's: the iOS 27 toolbar view is not
        // where its items are drawn.
        guard !navigation.isToolbarHidden, let items = navigation.topViewController?.toolbarItems else { return nil }
        let frames = items.compactMap(\.customView)
            .filter { $0.window === window && !$0.isHidden }
            .map { $0.convert($0.bounds, to: window) }
        guard let top = frames.map(\.minY).min(), let bottom = frames.map(\.maxY).max() else { return nil }
        let slack: CGFloat = 6
        return CGRect(x: 0, y: top - slack, width: window.bounds.width, height: bottom - top + slack * 2)
    }

    @MainActor
    private static func tabBar(
        of tabs: UITabBarController, covering point: CGPoint, over hit: UIView, in window: UIWindow
    ) -> UIView? {
        // A hidden bar (a pushed full-screen feed) guards nothing: no dead
        // zone where it was.
        guard !tabs.isTabBarHidden, let content = tabs.selectedViewController?.viewIfLoaded,
              hit.isDescendant(of: content), !hit.isDescendant(of: tabs.tabBar) else { return nil }
        if covers(tabs.tabBar, point, in: window) { return tabs.tabBar }
        if let accessory = tabs.bottomAccessory?.contentView, covers(accessory, point, in: window) {
            return tabs.tabBar
        }
        return nil
    }

    /// Whether `view` is on screen and its frame holds `point`.
    @MainActor
    private static func covers(_ view: UIView, _ point: CGPoint, in window: UIWindow) -> Bool {
        guard view.window === window, !view.isHidden, view.alpha > 0.01 else { return false }
        return view.convert(view.bounds, to: window).contains(point)
    }

    // MARK: - A screen's own floating bars (#1145)

    /// The floating bars screens have declared, held weakly — a bar goes with
    /// its screen, and nothing has to undeclare it — each with the items it
    /// names (`declareBar(_:items:)`).
    @MainActor private static let declared = NSMapTable<UIView, NSHashTable<UIView>>.weakToStrongObjects()

    /// Declares `bar` a bar: a view a screen floats over its own content
    /// that UIKit does not know is one — a pill row, a custom footer, a
    /// composer laid over a list or a map. A tap that starts inside its frame
    /// but beside its controls is swallowed, as beside a native bar's items;
    /// its controls take their taps as before, and a pan still reaches the
    /// content.
    ///
    /// - Parameter items: the bar's controls that are NOT its subviews — a
    ///   band laid behind a row of buttons the screen placed itself (the
    ///   camera's shutter row). They take their taps like the bar's own.
    ///
    /// Declare it once, when the screen builds it. Its frame is read at each
    /// touch, so it may move, resize, hide and come back.
    @MainActor
    public static func declareBar(_ bar: UIView, items: [UIView] = []) {
        let named = NSHashTable<UIView>.weakObjects()
        items.forEach(named.add)
        declared.setObject(named, forKey: bar)
    }

    /// Whether `hit` is `bar` itself or one of its controls.
    @MainActor
    static func isPart(_ hit: UIView, of bar: UIView) -> Bool {
        if hit.isDescendant(of: bar) { return true }
        return declared.object(forKey: bar)?.allObjects.contains { hit.isDescendant(of: $0) } ?? false
    }

    /// The declared bars on screen in `window`, for the audit.
    @MainActor
    public static func declaredBars(in window: UIWindow) -> [UIView] {
        (declared.keyEnumerator().allObjects as? [UIView] ?? []).filter { visible($0, in: window) }
    }

    /// A declared bar over `point`, when `hit` is its screen's content and not
    /// the bar itself.
    ///
    /// ⚠️ **ITS OWN SCREEN'S CONTENT ONLY.** A sheet or a screen presented
    /// over the bar's screen is not under the bar, even where their frames
    /// meet: its views are not descendants of the bar's screen.
    @MainActor
    private static func declaredBar(replacing hit: UIView, at point: CGPoint, in window: UIWindow) -> UIView? {
        for bar in declaredBars(in: window) where !isPart(hit, of: bar) {
            guard bar.convert(bar.bounds, to: window).contains(point),
                  let owner = screen(of: bar), hit.isDescendant(of: owner) else { continue }
            return bar
        }
        return nil
    }

    /// Whether `view` and every ancestor up to the window is shown.
    @MainActor
    private static func visible(_ view: UIView, in window: UIWindow) -> Bool {
        guard view.window === window else { return false }
        var current: UIView? = view
        while let shown = current, shown !== window {
            if shown.isHidden || shown.alpha <= 0.01 { return false }
            current = shown.superview
        }
        return true
    }

    /// The root view of the screen that owns `view`: its controller, or the
    /// controller that one is a child of, up to a navigation stack or the tab
    /// bar controller — a bar built by a child (a map's filter row) floats
    /// over its parent's content.
    @MainActor
    static func screen(of view: UIView) -> UIView? {
        var responder: UIResponder? = view.next
        while let current = responder, !(current is UIViewController) { responder = current.next }
        guard var controller = responder as? UIViewController else { return nil }
        while let parent = controller.parent, !(parent is UINavigationController), !(parent is UITabBarController) {
            controller = parent
        }
        return controller.viewIfLoaded
    }
}

/// Swallows the taps and long presses that start inside a bar's area over a
/// screen's content (#562), and lets everything else through.
///
/// - A touch elsewhere fails it at once: nothing waits on it.
/// - A finger that moves more than `slop` fails it too, so a pan that starts
///   under a bar scrolls as before.
/// - A finger lifted before then is a tap, and one held still for
///   `longPressDelay` a long press: the recogniser succeeds, and with
///   `cancelsTouchesInView` the content's views get `touchesCancelled`
///   instead of their tap — a button never fires, a cell never selects.
/// - The content's own tap and long-press recognisers wait for it to fail
///   (`shouldBeRequiredToFail(by:)`), so none of them fires first.
public final class BarTapShield: UIGestureRecognizer, UIGestureRecognizerDelegate {
    /// How far a finger may drift and still be a tap.
    static let slop: CGFloat = 10
    /// How long a still finger takes to become a long press — under the
    /// content's own (0.5 s for menus), so the shield always answers first.
    static let longPressDelay: TimeInterval = 0.35

    /// What a followed touch turns out to be.
    enum Outcome: Equatable {
        /// Still deciding.
        case undecided
        /// Swallowed: a tap or a long press.
        case swallowed
        /// Let through: it moved, so it is a pan.
        case passed
    }

    /// The decision, pure: how far the finger has gone, how long it has been
    /// down, and whether it has lifted.
    static func outcome(moved distance: CGFloat, after elapsed: TimeInterval, lifted: Bool) -> Outcome {
        if distance > slop { return .passed }
        if lifted || elapsed >= longPressDelay { return .swallowed }
        return .undecided
    }

    private var start: CGPoint = .zero
    private var began: TimeInterval = 0
    private var timer: Timer?

    public init() {
        super.init(target: nil, action: nil)
        cancelsTouchesInView = true
        delaysTouchesBegan = false
        delaysTouchesEnded = true
        delegate = self
    }

    override public func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        guard touches.count == 1, numberOfTouches <= 1, let touch = touches.first,
              let window = view as? UIWindow, let hit = touch.view else {
            state = .failed
            return
        }
        let point = touch.location(in: window)
        guard BarTouchGuard.bar(replacing: hit, at: point, in: window) != nil else {
            state = .failed
            return
        }
        start = point
        began = touch.timestamp
        let timer = Timer(timeInterval: Self.longPressDelay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.state == .possible else { return }
                self.state = .recognized
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    override public func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        guard state == .possible, let touch = touches.first, let window = view else { return }
        let point = touch.location(in: window)
        let outcome = Self.outcome(moved: hypot(point.x - start.x, point.y - start.y),
                                   after: touch.timestamp - began, lifted: false)
        if outcome == .passed { state = .failed }
    }

    override public func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        guard state == .possible, let touch = touches.first, let window = view else { return }
        let point = touch.location(in: window)
        let outcome = Self.outcome(moved: hypot(point.x - start.x, point.y - start.y),
                                   after: touch.timestamp - began, lifted: true)
        state = outcome == .swallowed ? .recognized : .failed
    }

    override public func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        state = .failed
    }

    override public func reset() {
        super.reset()
        timer?.invalidate()
        timer = nil
    }

    /// The content's taps and long presses wait for the shield to fail.
    /// Everything else — scroll views' pans, the edge swipes — runs as before.
    override public func shouldBeRequiredToFail(by other: UIGestureRecognizer) -> Bool {
        other is UITapGestureRecognizer || other is UILongPressGestureRecognizer
    }

    public func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        // Never blocks a pan, a pinch or a system gesture.
        !(other is UITapGestureRecognizer || other is UILongPressGestureRecognizer)
    }
}
