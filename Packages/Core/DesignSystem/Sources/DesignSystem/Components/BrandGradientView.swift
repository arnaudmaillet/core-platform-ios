import UIKit

/// The brand's gradient (`Palette.brandGradient`) as a view — the signature
/// of a key moment's hero button under `Palette.rules.heroButton = .gradient`
/// (#1169), bottom-left to top-right as the icon runs it. Takes no touch: a
/// button's background, not a control.
public final class BrandGradientView: UIView {
    override public class var layerClass: AnyClass { CAGradientLayer.self }
    private var gradient: CAGradientLayer { layer as! CAGradientLayer }

    override public init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        gradient.startPoint = CGPoint(x: 0, y: 1)
        gradient.endPoint = CGPoint(x: 1, y: 0)
        gradient.colors = Palette.brandGradient.map(\.cgColor)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}
