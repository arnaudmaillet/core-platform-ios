import UIKit

/// Taps inside a bar's area reach nothing behind it (#562).
///
/// Content runs edge to edge under the floating tab bar, its accessory, the
/// transparent navigation bars and the bottom toolbars. Those bars answer
/// hit-testing only on their items: a touch beside the tab capsule, in the nav
/// bar band off its buttons, or beside a toolbar platter fell through to the
/// cell, button or map marker underneath, and triggered it.
///
/// One guard for the whole app rather than one per screen: the main window
/// asks `BarTouchGuard` about every touch, and a touch that would land on a
/// screen's CONTENT while starting inside a visible bar of that screen's own
/// navigation or tab controller is handed to the bar instead, which does
/// nothing with it. Bar items, their glass and the tab bar's own overlays
/// are hit first and never rerouted.
///
/// Exceptions, by construction:
/// - the left edge (`edgeInset`): the drawer's edge swipe and the back swipe
///   start there;
/// - non-touch events and VoiceOver (it activates elements without
///   hit-testing a finger).
///
/// A pan that starts in a bar's area no longer scrolls the content under it:
/// the price of a guard that hit-testing alone can decide.
enum BarTouchGuard {
    /// The strip along the left edge left alone, for edge-swipe gestures.
    static let edgeInset: CGFloat = 28

    /// The bar that should take a touch at `point` (window coordinates)
    /// instead of `hit`, or nil to deliver it as hit-tested.
    @MainActor
    static func bar(replacing hit: UIView, at point: CGPoint, in window: UIWindow) -> UIView? {
        guard point.x > edgeInset else { return nil }
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
    static func toolbarBand(of navigation: UINavigationController, content: UIView, in window: UIWindow) -> CGRect? {
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
}

/// The app's main window: every touch goes past `BarTouchGuard`.
final class BarGuardWindow: UIWindow {
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let hit = super.hitTest(point, with: event)
        guard let hit, event?.type == .touches else { return hit }
        return BarTouchGuard.bar(replacing: hit, at: point, in: self) ?? hit
    }

    #if DEBUG
    /// What a finger would reach WITHOUT the guard — for the audit.
    func unguardedHitTest(_ point: CGPoint) -> UIView? {
        super.hitTest(point, with: nil)
    }
    #endif
}
