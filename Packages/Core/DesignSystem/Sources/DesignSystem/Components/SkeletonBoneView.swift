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
    ///
    /// ⚠️ ITS PEAK STAYS DARKER THAN THE PAGE (#1757). Over the opaque grey
    /// ground (`Surface.skeleton`, #1753) the old 55% band peaked at ~243 on
    /// a ~242 page: as it passed, a bone vanished into the screen and read as
    /// a transparent hole (the owner's recording, a profile's avatar). At
    /// 30% it peaks at ~237: a clear sweep, the bone always there.
    private static let highlight = UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor.white.withAlphaComponent(0.09)
            : UIColor.white.withAlphaComponent(0.3)
    }

    #if DEBUG
    static var debugHighlight: UIColor { highlight }
    #endif

    private let rounding: Rounding
    private let gradient = CAGradientLayer()
    /// The ground, under the band.
    ///
    /// ⚠️ A LAYER, NEVER THE VIEW'S `backgroundColor` (#1912). Inside a
    /// glass bar item UIKit paints a view's background itself, outside its
    /// masks (memory `glass-paints-background-color`): the author pill's
    /// loading face showed the bone as a disc with no cutout for its badge.
    /// A layer's colour is drawn where the layer is, under every mask.
    private let ground = CALayer()

    /// The bone's ground (#1753): `Surface.skeleton`, one opaque neutral grey,
    /// unless the host states another — the ONE way to change it (a raw
    /// `backgroundColor` is caught by `SkeletonGroundGuardTests`). `.clear`
    /// for a bone that adds only the sweep over a ground of its own.
    public var fill: UIColor {
        didSet { applyGround() }
    }

    /// The ground as drawn now. Tests.
    public var drawnGround: CGColor? { ground.backgroundColor }

    public init(rounding: Rounding = .capsule, fill: UIColor = Surface.skeleton) {
        self.rounding = rounding
        self.fill = fill
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        layer.addSublayer(ground)
        applyGround()
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

        registerForTraitChanges([UITraitUserInterfaceStyle.self, UITraitAccessibilityContrast.self]) { (self: Self, _) in
            self.applyGradientColors()
            self.applyGround()
        }
        // Backgrounding strips layer animations; coming back must resume the
        // sweep, not freeze the band mid-screen.
        NotificationCenter.default.addObserver(
            self, selector: #selector(reinstallIfVisible),
            name: UIApplication.willEnterForegroundNotification, object: nil
        )
        // ⚠️ STILL WHEN DECORATION RESTS (#789): an endless window-sized sweep
        // on a load that never answers (offline, a hung request) recomposited
        // the whole frame forever — the #580 cost. Reduce Motion, Low Power Mode
        // and an app at rest all still it; the bones stay, which is the state.
        for name in [UIAccessibility.reduceMotionStatusDidChangeNotification, .decorativeMotionDidChange] {
            NotificationCenter.default.addObserver(
                self, selector: #selector(reinstallIfVisible), name: name, object: nil
            )
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    public override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil {
            setNeedsLayout()
            if !isHidden { installSweep() }
        } else {
            gradient.removeAnimation(forKey: Self.sweepKey)
        }
    }

    /// ⚠️ A HIDDEN BONE RUNS NO SWEEP (#580, #1505). Every tile, card and
    /// carousel page carries one under its cover, hidden once the picture has
    /// landed: an infinite animation left on each would tick under every
    /// screen of pictures at rest. The epoch keeps a bone shown again in
    /// phase with the others.
    public override var isHidden: Bool {
        didSet {
            guard isHidden != oldValue else { return }
            if isHidden {
                gradient.removeAnimation(forKey: Self.sweepKey)
            } else if window != nil {
                installSweep()
            }
        }
    }

    public override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        ground.frame = bounds
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

    private func applyGround() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        ground.backgroundColor = fill.resolvedColor(with: traitCollection).cgColor
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

    /// Whether decoration is still: `MotionPreference.stillsDecoration`
    /// unless the host says otherwise. Read whenever the sweep is installed
    /// (entering a window, and on every motion change the bone observes). A
    /// seam for tests, here and in packages that host bones (EmoteKit), since
    /// the real answer is process-wide.
    public var stillsMotion: () -> Bool = { MotionPreference.stillsDecoration }

    private func installSweep() {
        gradient.removeAnimation(forKey: Self.sweepKey)
        // ⚠️ STILL MEANS NO BAND, not a frozen one: without its animation the
        // window-sized gradient falls back to its model locations and parks the
        // highlight mid-screen — a bright stripe across the middle bones.
        let still = stillsMotion()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        gradient.isHidden = still
        CATransaction.commit()
        guard !still else { return }
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
        if window != nil, !isHidden { installSweep() }
    }

    /// Whether the sweep is running, and whether its band shows. Tests.
    public var isSweeping: Bool { gradient.animation(forKey: Self.sweepKey) != nil }
    public var showsBand: Bool { !gradient.isHidden }
}
