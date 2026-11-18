import UIKit

/// A view backed by a `CAGradientLayer`, sized automatically with its bounds.
public final class GradientView: UIView {
    override public class var layerClass: AnyClass { CAGradientLayer.self }
    private var gradientLayer: CAGradientLayer { layer as! CAGradientLayer }

    public init(colors: [UIColor],
                locations: [NSNumber]? = nil,
                startPoint: CGPoint = CGPoint(x: 0.5, y: 0),
                endPoint: CGPoint = CGPoint(x: 0.5, y: 1)) {
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        gradientLayer.colors = colors.map(\.cgColor)
        gradientLayer.locations = locations
        gradientLayer.startPoint = startPoint
        gradientLayer.endPoint = endPoint
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Re-tunes the gradient's stop positions (the frost masks compute
    /// theirs from the engaged geometry at install time).
    public func setLocations(_ locations: [NSNumber]) {
        gradientLayer.locations = locations
    }

    /// Re-tunes the gradient's colours, unanimated.
    public func setColors(_ colors: [UIColor]) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        gradientLayer.colors = colors.map(\.cgColor)
        CATransaction.commit()
    }
}
