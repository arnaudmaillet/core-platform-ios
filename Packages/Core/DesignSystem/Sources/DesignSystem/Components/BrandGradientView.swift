import UIKit

/// A gradient as a view, bottom-left to top-right as the icon runs it: the
/// brand's (`Palette.brandGradient`, a key moment's hero button under
/// `Palette.rules.heroButton = .gradient`, #1169) by default, or the stops a
/// caller gives — the prominent button's fill (`Palette.primaryGradient`,
/// #1178).
/// Dynamic stops re-resolve on an appearance or accent theme change (#1379).
/// Takes no touch: a button's background, not a control.
public final class BrandGradientView: UIView {
    override public class var layerClass: AnyClass { CAGradientLayer.self }
    private var gradient: CAGradientLayer { layer as! CAGradientLayer }
    private let stops: [UIColor]

    public init(colors: [UIColor] = Palette.brandGradient) {
        stops = colors
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        gradient.startPoint = CGPoint(x: 0, y: 1)
        gradient.endPoint = CGPoint(x: 1, y: 0)
        resolveColours()
        registerForTraitChanges(
            [UITraitUserInterfaceStyle.self, UITraitAccessibilityContrast.self, AccentThemeTrait.self]
        ) { (view: Self, _) in
            view.resolveColours()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// The stops as drawn now, resolved for the view's appearance.
    var drawnColours: [UIColor] { stops.map { $0.resolvedColor(with: traitCollection) } }

    private func resolveColours() {
        gradient.colors = drawnColours.map(\.cgColor)
    }
}
