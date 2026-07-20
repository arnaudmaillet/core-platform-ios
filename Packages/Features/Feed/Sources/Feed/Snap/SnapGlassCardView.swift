import UIKit

/// A single floating Liquid Glass card: the shared visual style — the
/// `systemThinMaterialDark` blur, the hairline white border, and the
/// continuous corner radius — that both engaged-card components draw
/// independently, so each renders as its own distinct glass surface.
///
/// The blur is MATERIALIZED via the `effect` property (alpha on an effect
/// view is unsupported) and only IN A WINDOW: creating a real `UIBlurEffect`
/// contacts the render server, a multi-second main-thread stall on headless
/// CI simulators that unit-tested views must never pay. Clipping needs
/// `clipsToBounds` — an effect view's backdrop ignores the layer radius on
/// its own (the count bubble's doctrine).
final class SnapGlassCardView: UIVisualEffectView {
    init() {
        super.init(effect: nil)
        clipsToBounds = true
        layer.cornerRadius = SnapCommentsLayout.stripCardCornerRadius
        layer.cornerCurve = .continuous
        layer.borderWidth = 0.5
        layer.borderColor = UIColor.white.withAlphaComponent(0.15).cgColor
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Materializes (or dissolves) the glass. Materialization is
    /// window-guarded and idempotent; the dissolve is always safe. Call
    /// inside the engagement's animation block — the `effect` transition
    /// animates.
    func setGlassActive(_ active: Bool) {
        if active {
            guard window != nil, effect == nil else { return }
            effect = UIBlurEffect(style: .systemThinMaterialDark)
        } else {
            effect = nil
        }
    }
}
