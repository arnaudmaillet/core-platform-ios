import UIKit

/// The lift a long-pressed row takes into a context menu's platter.
///
/// ⚠️ THE PLATTER CONTRACT, learned on the chat's bubbles and the reason this
/// exists as one helper rather than as each row's own guess:
///
///  1. The preview view's bounds must COINCIDE with `visiblePath`'s bounds.
///     The platter aligns itself to the path but restores the VIEW, so a path
///     that is off the view's centre leaves the row displaced by the
///     difference after dismissal (measured once at 47pt).
///  2. The view's own `backgroundColor` is stripped and repainted from the
///     parameters. A row that wants a fill under it in the platter says so
///     through `platterColor`, never through its own background.
///
/// So the lifted view should be a container whose bounds ARE the shape — for
/// a flat row, a clear plate that already carries the padding the lift wants
/// around its text — and the path is simply those bounds, rounded.
@MainActor
public enum LiftedPreview {
    public static func targeted(
        view: UIView,
        cornerRadius: CGFloat,
        platterColor: UIColor
    ) -> UITargetedPreview {
        UITargetedPreview(
            view: view,
            parameters: parameters(for: view.bounds, cornerRadius: cornerRadius, platterColor: platterColor)
        )
    }

    /// The parameters on their own: the path is `bounds`, rounded, and
    /// nothing else — which is what keeps rule 1 true by construction.
    public static func parameters(
        for bounds: CGRect,
        cornerRadius: CGFloat,
        platterColor: UIColor
    ) -> UIPreviewParameters {
        let parameters = UIPreviewParameters()
        parameters.visiblePath = UIBezierPath(roundedRect: bounds, cornerRadius: cornerRadius)
        parameters.backgroundColor = platterColor
        return parameters
    }
}
