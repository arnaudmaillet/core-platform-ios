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
/// A control that can be told to re-assert its appearance after a transition.
///
/// Interactive transitions rasterise and re-parent the views they carry, and
/// glass-hosted controls do not always come back whole: the observed failure is a
/// segment row whose capsule returns at full width with only the SELECTED title
/// drawn, the other two simply absent. Nothing in this app's own code clears
/// them, so the repair cannot be "stop doing that" — it has to be "rebuild the
/// appearance once the transition is over", which is what this is for.
@MainActor
public protocol TransitionRestorable {
    /// Re-assert visibility, geometry and content. Must be idempotent and cheap:
    /// it runs on every transition completion, including ones that were fine.
    func restoreAfterTransition()
}

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

    private let contents: [UIView]
    private var capsules: [UIVisualEffectView] = []

    public init(leading: UIView, trailing: UIView) {
        contents = [leading, trailing]
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        let leadingCapsule = GlassCapsule.wrap(leading)
        let trailingCapsule = GlassCapsule.wrap(trailing)
        capsules = [leadingCapsule, trailingCapsule]
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

// MARK: - TransitionRestorable

extension InlineFilterTrayView: TransitionRestorable {
    /// Rebuilds the tray's appearance from the top down after a transition.
    ///
    /// Three layers each get their own treatment because each can be left in a
    /// different broken state: the tray itself, the two glass capsules, and the
    /// bare controls inside them.
    ///
    /// The capsules also have their `clipsToBounds` re-cleared. They are shaped
    /// with `cornerConfiguration` precisely so nothing has to clip — a masked
    /// radius does not survive a `UIMenu`'s portal morph — so a capsule that
    /// comes back clipping is a leak, and a clipping capsule is exactly what cuts
    /// the outer segments off.
    public func restoreAfterTransition() {
        alpha = 1
        isHidden = false
        transform = .identity
        for capsule in capsules {
            capsule.alpha = 1
            capsule.isHidden = false
            capsule.transform = .identity
            capsule.clipsToBounds = false
            capsule.contentView.alpha = 1
            capsule.contentView.isHidden = false
        }
        for content in contents {
            content.alpha = 1
            content.isHidden = false
            content.transform = .identity
            (content as? TransitionRestorable)?.restoreAfterTransition()
        }
        setNeedsLayout()
        layoutIfNeeded()
    }
}
