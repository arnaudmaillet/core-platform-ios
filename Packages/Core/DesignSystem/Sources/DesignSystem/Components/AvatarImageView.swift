import UIKit

/// A circular avatar image view: aspect-fill, clipped, and geometrically
/// incapable of rendering as anything but a perfect circle — the corner
/// radius is re-bound to half the bounds on every layout pass, so any size
/// (or a future size change) stays exactly round at every screen scale, with
/// no hand-copied radius constants to drift.
///
/// `barDiameter` is the one size for toolbar/identity avatars — the Maps
/// profile button and the snap feed's author pill both read it here, so the
/// two surfaces cannot fall out of alignment.
public final class AvatarImageView: UIImageView {
    /// The standard toolbar/identity avatar diameter.
    public static let barDiameter: CGFloat = 32

    public init() {
        super.init(frame: .zero)
        contentMode = .scaleAspectFill
        clipsToBounds = true
        layer.cornerCurve = .circular
        // The bar diameter until a layout pass says otherwise, so a copy taken
        // before one (a flight's chrome) is already a disc.
        layer.cornerRadius = Self.barDiameter / 2
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    public override func layoutSubviews() {
        super.layoutSubviews()
        // Never to zero: a pass before the view has a size would draw a square.
        let side = min(bounds.width, bounds.height)
        if side > 0 { layer.cornerRadius = side / 2 }
        CircleMask.apply(to: self)
    }
}

/// A circle that nothing else can reshape: an oval shape-layer MASK, redrawn
/// from the bounds.
///
/// ⚠️ **`layer.cornerRadius` WAS NOT ENOUGH ON A DEVICE.** Inside the snap
/// feed's navigation-bar pill (a glass bar item) an iPhone drew the author's
/// avatar and its initials plate as rounded SQUARES (a squircle of about a
/// third of the side, the pill's concentric radius), while the simulator drew
/// discs and the same view in the bottom toolbar stayed round. A mask is not a
/// corner: no corner configuration a container applies can override it.
enum CircleMask {
    static func apply(to view: UIView) {
        let bounds = view.bounds
        guard bounds.width > 0, bounds.height > 0 else { return }
        let mask = (view.layer.mask as? CAShapeLayer) ?? CAShapeLayer()
        let path = UIBezierPath(ovalIn: bounds).cgPath
        guard mask.path != path || view.layer.mask !== mask else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        mask.frame = bounds
        mask.path = path
        view.layer.mask = mask
        CATransaction.commit()
    }
}
