import UIKit

/// Symbol feedback on tap: the icon bounces where it is, once, when a viewer
/// acts on it.
///
/// ⚠️ **Attached at construction, not at each call site.** The point is that a
/// button built through these helpers cannot forget the feedback, so a new icon
/// added next month gets it without anyone remembering to ask. The two hosts
/// need different mechanics — a `UIButton` bounces its `imageView`, a bar item
/// bounces itself — which is exactly why they live together here rather than
/// being re-derived at each site.
public extension UIButton {
    /// Bounces this button's symbol whenever its action fires.
    ///
    /// The effect rides `.primaryActionTriggered`, which is what a tap, a
    /// keyboard activation and an accessibility action all raise — so the
    /// feedback follows the ACTION rather than the touch, and a button
    /// activated by VoiceOver animates exactly as a tapped one does.
    @discardableResult
    func bouncesSymbolOnTap() -> Self {
        addAction(
            UIAction { [weak self] _ in
                // The image view is the symbol's host; the button itself is not
                // a symbol and has nothing to animate.
                self?.imageView?.addSymbolEffect(.bounce, options: .nonRepeating)
            },
            for: .primaryActionTriggered
        )
        return self
    }
}

public extension UIBarButtonItem {
    /// A bar item whose symbol bounces when it is used.
    ///
    /// Composed into the `UIAction` rather than added alongside it: a bar item
    /// has one primary action and no control events to hang a second observer
    /// on, so the only place the tap is observable is inside the handler the
    /// owner already provides.
    convenience init(
        bouncingImage image: UIImage?,
        accessibilityLabel: String? = nil,
        handler: @escaping () -> Void
    ) {
        var item: UIBarButtonItem?
        let action = UIAction { _ in
            item?.addSymbolEffect(.bounce, options: .nonRepeating)
            handler()
        }
        self.init(image: image, primaryAction: action)
        item = self
        self.accessibilityLabel = accessibilityLabel
    }

    /// Bounces this item's symbol now — for owners whose action is already
    /// wired, and for the paths a tap cannot reach (a menu item chosen from a
    /// tray, a QA hook driving the same code a finger would).
    func bounceSymbol() {
        addSymbolEffect(.bounce, options: .nonRepeating)
    }
}

public extension UIImageView {
    /// Bounces this symbol once — the shared spelling, so call sites do not each
    /// pick their own effect and options.
    func bounceSymbol() {
        addSymbolEffect(.bounce, options: .nonRepeating)
    }
}
