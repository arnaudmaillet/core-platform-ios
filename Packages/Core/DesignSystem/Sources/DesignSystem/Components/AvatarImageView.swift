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
    }
}
