import UIKit

/// A circular avatar image view: aspect-fill, clipped, and geometrically
/// incapable of rendering as anything but its `shape` (a perfect circle unless
/// a surface asks otherwise) — the corner radius is re-bound to the bounds on
/// every layout pass, so any size (or a future size change) keeps the outline
/// exactly at every screen scale, with no hand-copied radius constants to
/// drift.
///
/// `barDiameter` is the one size for toolbar/identity avatars — the Maps
/// profile button and the snap feed's author pill both read it here, so the
/// two surfaces cannot fall out of alignment.
public final class AvatarImageView: UIImageView {
    /// The standard toolbar/identity avatar diameter.
    public static let barDiameter: CGFloat = 32

    /// The outline — a disc unless a surface asks for its rounded square.
    public var shape: AvatarShape = .circle {
        didSet {
            guard shape != oldValue else { return }
            let side = min(bounds.width, bounds.height)
            AvatarShapeMask.round(self, as: shape, side: side > 0 ? side : Self.barDiameter)
            setNeedsLayout()
        }
    }

    public init() {
        super.init(frame: .zero)
        contentMode = .scaleAspectFill
        clipsToBounds = true
        // The bar diameter until a layout pass says otherwise, so a copy taken
        // before one (a flight's chrome) is already a disc.
        AvatarShapeMask.round(self, as: shape, side: Self.barDiameter)
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    public override func layoutSubviews() {
        super.layoutSubviews()
        // Never to zero: a pass before the view has a size would draw a square.
        let side = min(bounds.width, bounds.height)
        AvatarShapeMask.round(self, as: shape, side: side)
        AvatarShapeMask.apply(shape, to: self)
    }
}
