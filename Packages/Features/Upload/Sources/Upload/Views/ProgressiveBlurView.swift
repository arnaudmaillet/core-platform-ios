import UIKit

/// A blur that DISSOLVES along its length instead of ending on a hard edge:
/// clear at the top, full material at the bottom.
///
/// The picker wears one from the top of the chosen-media strip to the foot of
/// the screen, so the album runs on underneath and simply loses definition as it
/// passes behind the chrome.
///
/// **This masked-effect-view pair IS the native way to build a blur gradient.**
/// UIKit has no gradient-blur type, blur strength is not a settable property,
/// and alpha on an effect view is unsupported — so the material is the system's
/// own and the gradient decides only WHERE it lands.
///
/// ⚠️ **THE MASK IS A VIEW ASSIGNED TO `mask`, NEVER A LAYER ON `layer`.** UIKit
/// propagates a view mask through the effect's internal backdrop layers; masking
/// the layer directly breaks effect rendering outright.
///
/// ⚠️ **AND ITS FRAME IS RE-BOUND EVERY LAYOUT PASS.** The band resizes — the
/// strip comes and goes with the selection — and a stale mask frame shears the
/// ramp.
///
/// Both mechanics are Feed's `ProgressiveFrostView` (`SnapCommentsPresentation`),
/// which is where they were established and measured. This is a deliberately
/// smaller copy rather than a promotion of that type: it would have to move with
/// its own `GradientView` — `internal` to Feed, so unreachable from here — and it
/// carries a themed veil and a variable ramp length that this screen has no use
/// for. Features cannot import one another; ~20 lines duplicated is the cheaper
/// half of that trade.
///
/// ⚠️ **THE EFFECT IS SET IN `didMoveToWindow`, NOT IN `init`.** Materialising a
/// blur in a property initialiser contacts the render server, which on a
/// headless CI simulator has stalled the main actor for tens of seconds and
/// starved unrelated tests. Five components in this app state it the same way.
final class ProgressiveBlurView: UIVisualEffectView {
    private let ramp = RampView()

    init() {
        super.init(effect: nil)
        isUserInteractionEnabled = false
        mask = ramp
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard window != nil, effect == nil else { return }
        effect = UIBlurEffect(style: .systemThinMaterial)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        ramp.frame = bounds
    }

    /// The mask itself: clear at the top, opaque from `fullyOpaqueAt` down.
    ///
    /// A `UIView` whose backing layer IS the gradient, so there is no second
    /// layer to keep in step with the view's bounds.
    private final class RampView: UIView {
        override class var layerClass: AnyClass { CAGradientLayer.self }

        /// Where the ramp finishes. Below this the material is at full strength;
        /// above it the album is untouched.
        private static let fullyOpaqueAt: NSNumber = 0.55

        override init(frame: CGRect) {
            super.init(frame: frame)
            guard let gradient = layer as? CAGradientLayer else { return }
            gradient.colors = [UIColor.clear.cgColor, UIColor.black.cgColor]
            gradient.locations = [0, Self.fullyOpaqueAt]
            gradient.startPoint = CGPoint(x: 0.5, y: 0)
            gradient.endPoint = CGPoint(x: 0.5, y: 1)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    }
}
