import UIKit

/// One shimmering placeholder bone of a skeleton screen: a quiet fill in the
/// shape of the content to come, swept by a soft highlight while it waits.
///
/// The sweep is pure Core Animation — a `CAGradientLayer` whose `locations`
/// glide left to right on an infinite loop, so a screenful of bones costs no
/// main-thread time at all. Two properties make many bones read as ONE
/// loading surface instead of a field of blinking parts:
///
/// - **Window-coherent geometry**: every bone stretches its gradient to the
///   window's frame (clipped to its own rounded shape), so the highlight is
///   a single band of light travelling across the whole screen, not a
///   per-view twinkle.
/// - **A shared clock**: the animation's `beginTime` is a fixed epoch in the
///   layers' common timebase, so bones added at different moments — separate
///   cells, separate screens — are always mid-sweep in the same phase.
///
/// Animations are re-installed whenever the view re-enters a window (Core
/// Animation strips them on backgrounding and detachment), and the gradient's
/// colors re-resolve on light/dark changes.
public final class SkeletonBoneView: UIView {
    /// The bone's silhouette.
    public enum Rounding {
        /// A fixed continuous corner radius (0 for square edges).
        case fixed(CGFloat)
        /// A full pill/circle: radius tracks half the bone's height.
        case capsule
    }

    /// All bones sweep in lockstep: same duration, same epoch (1s past the
    /// timebase origin — any fixed instant in the past works).
    private static let sweepDuration: CFTimeInterval = 1.6
    private static let sweepEpoch: CFTimeInterval = 1

    /// The travelling band, over the base fill. Light mode gets a brighter
    /// pass than dark, where a faint lift is all the surface can carry.
    private static let highlight = UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor.white.withAlphaComponent(0.09)
            : UIColor.white.withAlphaComponent(0.55)
    }

    private let rounding: Rounding
    private let gradient = CAGradientLayer()

    public init(rounding: Rounding = .capsule) {
        self.rounding = rounding
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        backgroundColor = .tertiarySystemFill
        layer.cornerCurve = .continuous
        layer.masksToBounds = true
        if case .fixed(let radius) = rounding {
            layer.cornerRadius = radius
        }

        // A near-horizontal diagonal: reads as light, not as a scanline.
        gradient.startPoint = CGPoint(x: 0, y: 0.45)
        gradient.endPoint = CGPoint(x: 1, y: 0.55)
        gradient.locations = [0, 0.5, 1]
        layer.addSublayer(gradient)
        applyGradientColors()

        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (self: Self, _) in
            self.applyGradientColors()
        }
        // Backgrounding strips layer animations; coming back must resume the
        // sweep, not freeze the band mid-screen.
        NotificationCenter.default.addObserver(
            self, selector: #selector(reinstallIfVisible),
            name: UIApplication.willEnterForegroundNotification, object: nil
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    public override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil {
            setNeedsLayout()
            installSweep()
        } else {
            gradient.removeAnimation(forKey: Self.sweepKey)
        }
    }

    public override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if let window {
            // Stretch the gradient to the window so every bone shows the same
            // screen-wide band, each clipped to its own silhouette.
            let origin = convert(CGPoint.zero, to: window)
            gradient.frame = CGRect(
                x: -origin.x, y: -origin.y,
                width: window.bounds.width, height: window.bounds.height
            )
        } else {
            gradient.frame = bounds
        }
        if case .capsule = rounding {
            layer.cornerRadius = bounds.height / 2
        }
        CATransaction.commit()
    }

    /// CGColors don't track dynamic providers; resolve for the current traits
    /// (and again on every light/dark change).
    private func applyGradientColors() {
        let band = Self.highlight.resolvedColor(with: traitCollection)
        gradient.colors = [
            band.withAlphaComponent(0).cgColor,
            band.cgColor,
            band.withAlphaComponent(0).cgColor
        ]
    }

    private static let sweepKey = "skeleton.sweep"

    private func installSweep() {
        gradient.removeAnimation(forKey: Self.sweepKey)
        let sweep = CABasicAnimation(keyPath: "locations")
        sweep.fromValue = [-0.4, -0.2, 0]
        sweep.toValue = [1, 1.2, 1.4]
        sweep.duration = Self.sweepDuration
        sweep.repeatCount = .infinity
        // A fixed epoch in the shared timebase phase-locks every bone.
        sweep.beginTime = Self.sweepEpoch
        gradient.add(sweep, forKey: Self.sweepKey)
    }

    @objc private func reinstallIfVisible() {
        if window != nil { installSweep() }
    }
}
