import UIKit

/// The outline an avatar is clipped to: the app's disc, or — for a surface
/// that wants a face to read as a tile rather than a badge — a super-ellipse
/// that is nearly one.
public enum AvatarShape: Equatable, Sendable {
    /// A perfect circle, whatever the size. Every avatar's default.
    case circle
    /// `|x|ⁿ + |y|ⁿ = 1` over the bounds: 2 is the circle, 4–5 an app icon.
    /// Around 2.5 it reads as a circle swelling toward its corners — sides
    /// that bulge, no straight edge anywhere.
    ///
    /// ⚠️ NOT A ROUNDED RECT, AND NEITHER CORNER CURVE GETS THERE. The
    /// continuous curve has nothing between an app icon (radius ≈ 0.30 of the
    /// side) and a plain disc (≥ 0.33, where UIKit draws a circle); circular
    /// arcs leave a flat run on every side. Both were tried on For You's
    /// Friends row (2026-10-04) and read as "a square" or "a circle".
    case superellipse(exponent: CGFloat)

    /// The corner radius for an avatar `side` points across — for a layer that
    /// can only wear a corner (a flight's card, a stand-in).
    ///
    /// For the super-ellipse: the circular-arc radius whose corner passes
    /// through the same point on the diagonal, the one place a corner is most
    /// visible — under a point off the true outline at a face's size.
    public func cornerRadius(side: CGFloat) -> CGFloat {
        switch self {
        case .circle:
            return side / 2
        case .superellipse(let exponent):
            // The diagonal point at `d` half-sides from the centre; an arc of
            // radius r (in half-sides) reaches (1 - r) + r/√2 there.
            let d = pow(2, -1 / max(exponent, 2))
            let r = (1 - d) / (1 - 1 / 2.squareRoot())
            return min(r, 1) * side / 2
        }
    }

    /// The curve `cornerRadius(side:)` is meant for.
    public var cornerCurve: CALayerCornerCurve { .circular }

    /// The outline as a path, for whatever cannot wear a layer's corner — a
    /// mask, a ring, a context menu's lift, a hand-clipped snapshot.
    public func path(in rect: CGRect) -> UIBezierPath {
        switch self {
        case .circle:
            return UIBezierPath(ovalIn: rect)
        case .superellipse(let exponent):
            return Self.superellipse(in: rect, exponent: exponent)
        }
    }

    /// The super-ellipse inscribed in `rect`, as a closed polygon fine enough
    /// to be smooth at any avatar size (under 0.1pt of chord error at 100pt).
    static func superellipse(in rect: CGRect, exponent: CGFloat, segments: Int = 192) -> UIBezierPath {
        let path = UIBezierPath()
        let a = rect.width / 2, b = rect.height / 2
        let power = 2 / max(exponent, 2)
        for i in 0..<segments {
            let t = 2 * CGFloat.pi * CGFloat(i) / CGFloat(segments)
            let c = cos(t), s = sin(t)
            let point = CGPoint(
                x: rect.midX + a * copysign(pow(abs(c), power), c),
                y: rect.midY + b * copysign(pow(abs(s), power), s)
            )
            if i == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        path.close()
        return path
    }
}

/// The avatar's outline as nothing else can reshape it: a shape-layer MASK,
/// redrawn from the bounds.
///
/// ⚠️ **`layer.cornerRadius` WAS NOT ENOUGH ON A DEVICE.** Inside the snap
/// feed's navigation-bar pill (a glass bar item) an iPhone drew the author's
/// avatar and its initials plate as rounded SQUARES (a squircle of about a
/// third of the side, the pill's concentric radius), while the simulator drew
/// discs and the same view in the bottom toolbar stayed round. A mask is not a
/// corner: no corner configuration a container applies can override it.
enum AvatarShapeMask {
    static func apply(_ shape: AvatarShape, to view: UIView) {
        let bounds = view.bounds
        guard bounds.width > 0, bounds.height > 0 else { return }
        let mask = (view.layer.mask as? CAShapeLayer) ?? CAShapeLayer()
        let path = shape.path(in: bounds).cgPath
        guard mask.path != path || view.layer.mask !== mask else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        mask.frame = bounds
        mask.path = path
        view.layer.mask = mask
        CATransaction.commit()
    }

    /// The corner a view wears under the mask — so a copy that drops the mask
    /// (a snapshot, a flight's twin) still has the outline, near enough.
    static func round(_ view: UIView, as shape: AvatarShape, side: CGFloat) {
        guard side > 0 else { return }
        view.layer.cornerRadius = shape.cornerRadius(side: side)
        view.layer.cornerCurve = shape.cornerCurve
    }
}
