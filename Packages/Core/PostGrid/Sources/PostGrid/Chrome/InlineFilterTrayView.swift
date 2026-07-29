import DesignSystem
import UIKit

/// One glass capsule around one bare control.
///
/// **The capsules are supplied here, and only here.** `GlassSegmentRow` and
/// `GlassMenuButton` deliberately carry no material of their own because the
/// iOS 26 toolbar composites every bar item through its own neutral glass —
/// both types document that adding an effect inside that capsule renders as
/// a dark "double bubble". Outside the toolbar there is no such capsule, and
/// the items render bare (verified: flat text on the background), so each
/// gets exactly ONE `UIGlassEffect` host. One material, never two.
public enum GlassCapsule {
    /// `isInteractive` is what gives the system's press response — the same
    /// reason `InboxCategoryBar` sets it rather than animating a highlight by
    /// hand.
    ///
    /// The corner shape is `cornerConfiguration`, NOT `clipsToBounds` plus a
    /// layer radius. Those are not equivalent under a context menu: a hosted
    /// menu button presents a `UIMenu`, and UIKit morphs a portal of this view
    /// out and back for that. A layer-masked radius is not part of what it
    /// interpolates, so the capsule dismissed as a hard SQUARE for a frame
    /// before snapping back to a bubble. `cornerConfiguration` is a property
    /// UIKit owns and animates with the view, so the shape survives the morph —
    /// the same reason `ToastView` and `ChatInputBar` state it this way.
    @MainActor
    public static func wrap(_ content: UIView) -> UIVisualEffectView {
        let effect = UIGlassEffect()
        effect.isInteractive = true
        let host = UIVisualEffectView(effect: effect)
        host.translatesAutoresizingMaskIntoConstraints = false
        host.cornerConfiguration = .capsule()
        content.translatesAutoresizingMaskIntoConstraints = false
        host.contentView.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: host.contentView.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: host.contentView.trailingAnchor),
            content.centerYAnchor.constraint(equalTo: host.contentView.centerYAnchor)
        ])
        return host
    }
}

/// The filter tray as a screen hosts it, rather than a navigation toolbar:
/// a leading segment capsule and a trailing circular menu bubble, each in its
/// own glass.
///
/// This placement exists for a hard UIKit reason, not a style preference. The
/// tray normally rides the navigation controller's toolbar, which iOS positions
/// against the *window's* bottom safe area. Below a `UITabBarController` that
/// lands the tray inside the tab bar's band, and no inset, margin or
/// additional-safe-area applied from outside moves it (all three measured). A
/// screen that keeps a tab bar beneath it therefore has to host the tray
/// itself — pinned above its own `safeAreaLayoutGuide.bottom`, which inside a
/// tab bar controller IS the top of the bar. The owner supplies that pin; this
/// view supplies the contents.
public final class InlineFilterTrayView: UIView {
    /// `GlassSegmentRow`'s resting height — the inline tray's own height.
    ///
    /// `nonisolated` because the owner reads these to size and pin the tray,
    /// often from a nested constants type that carries no actor isolation of
    /// its own; a `UIView` subclass's statics are `@MainActor` by inference and
    /// would be unreachable from there.
    public nonisolated static let height: CGFloat = 42
    /// Between the tray and the bar beneath it, so the two glass rows read
    /// as separate objects rather than one stack.
    public nonisolated static let spacingBelow: CGFloat = 8

    public init(leading: UIView, trailing: UIView) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        let leadingCapsule = GlassCapsule.wrap(leading)
        let trailingCapsule = GlassCapsule.wrap(trailing)
        addSubview(leadingCapsule)
        addSubview(trailingCapsule)
        NSLayoutConstraint.activate([
            leadingCapsule.leadingAnchor.constraint(equalTo: leadingAnchor),
            leadingCapsule.topAnchor.constraint(equalTo: topAnchor),
            leadingCapsule.bottomAnchor.constraint(equalTo: bottomAnchor),
            trailingCapsule.trailingAnchor.constraint(equalTo: trailingAnchor),
            trailingCapsule.topAnchor.constraint(equalTo: topAnchor),
            trailingCapsule.bottomAnchor.constraint(equalTo: bottomAnchor),
            trailingCapsule.widthAnchor.constraint(equalTo: trailingCapsule.heightAnchor),
            trailingCapsule.leadingAnchor.constraint(
                greaterThanOrEqualTo: leadingCapsule.trailingAnchor, constant: Spacing.sm
            )
        ])
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}
