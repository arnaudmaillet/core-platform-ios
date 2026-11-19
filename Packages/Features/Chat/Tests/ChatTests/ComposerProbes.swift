import Testing
import UIKit
@testable import ThreadKit

/// The composer's probes the conversation's screen tests read: the same ones
/// Feed's `SnapActionColumnLayoutTests` reads the post page's composer with.
/// They came with the conversation's tests when the screen moved to Chat
/// (#2380): a test target cannot reach another package's tests.
@MainActor
enum ComposerProbes {
    /// The composer's column in `space`: the stake (nil when the bar shows
    /// none), and the rail slot — the rail button, laid out on its station
    /// whatever it wears.
    static func composerColumn(
        in root: UIView, space: UICoordinateSpace
    ) throws -> (stake: CGRect?, rail: CGRect, field: CGRect, bar: CommentsInputBar) {
        let bar = try #require(firstView(CommentsInputBar.self, in: root))
        // The snap panel's stake bubble wears the like face (#668).
        let stake = button(bar, "Like").flatMap { $0.isHidden ? nil : $0 }
        let rail = bar.debugRailButton
        let field = try #require(fieldView(in: bar))
        return (
            stake.map { $0.convert($0.bounds, to: space) },
            rail.convert(rail.bounds, to: space),
            field.convert(field.bounds, to: space),
            bar
        )
    }

    static func button(_ bar: UIView, _ label: String) -> UIButton? {
        bar.subviews.compactMap { $0 as? UIButton }.first { $0.accessibilityLabel == label }
    }

    /// The field: the bar's effect view that holds the text view.
    static func fieldView(in bar: CommentsInputBar) -> UIVisualEffectView? {
        bar.subviews.compactMap { $0 as? UIVisualEffectView }.first { firstView(UITextView.self, in: $0) != nil }
    }

    static func firstView<T: UIView>(_ type: T.Type, in view: UIView) -> T? {
        if let match = view as? T { return match }
        for subview in view.subviews {
            if let match = firstView(type, in: subview) { return match }
        }
        return nil
    }

    /// A stand-in KEYBOARD for `bar`, in `root`: a guide whose top is the
    /// returned constraint's constant below `root`'s top — what the host's
    /// `keyboardLayoutGuide` is to the bar, which the package test host can
    /// never raise. Starts at `top`.
    static func fakeKeyboard(in root: UIView, for bar: CommentsInputBar, top: CGFloat) -> NSLayoutConstraint {
        let keyboard = UILayoutGuide()
        root.addLayoutGuide(keyboard)
        let edge = keyboard.topAnchor.constraint(equalTo: root.topAnchor, constant: top)
        NSLayoutConstraint.activate([
            edge,
            keyboard.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            keyboard.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            keyboard.heightAnchor.constraint(equalToConstant: 1),
        ])
        bar.riseWithKeyboard(of: keyboard)
        return edge
    }

    /// The view UIKit made for a stock bar item (#1679) — its `view`, read
    /// the way UIKit's own tests do; nil before the bar hosts it. Tests only.
    static func hostedView(of item: UIBarButtonItem) -> UIView? {
        let selector = NSSelectorFromString("view")
        guard item.responds(to: selector) else { return nil }
        let view = item.perform(selector)?.takeUnretainedValue() as? UIView
        return view?.window == nil ? nil : view
    }

    /// The glass bubble a toolbar item stands in, in `window`: its first
    /// ancestor taller than the item (UIKit insets the item in its glass).
    ///
    /// ⚠️ READ OFF THE BAR, NEVER ASSUMED. The bubble's height is UIKit's:
    /// 48pt in the app on iOS 27, 44pt for the same lone ⋯ in the package
    /// test host.
    static func glassFrame(of item: UIView, in window: UIWindow) -> CGRect? {
        var node = item.superview
        while let view = node, view !== window {
            if view.bounds.height > item.bounds.height + 0.5 { return view.convert(view.bounds, to: window) }
            node = view.superview
        }
        return nil
    }
}
