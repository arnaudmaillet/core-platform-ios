import UIKit

/// The selection pill as a Liquid Glass lens that lifts while it is held or
/// travelling — the native tab bar's and `UISegmentedControl`'s indicator,
/// rebuilt from film of the native tab bar in this app, for BOTH selectors
/// (`PagedTabBar`, `IconSelectorBar`).
///
/// ⚠️ **A SPIKE, behind `-selector-glass-lens`.** What the film says the
/// native lens is, and what this does about each:
///
/// - **Clear**, with the bar's frost showing through it, magnified. A public
///   `UIGlassEffect` nested in the host's glass samples the RAW page behind
///   the bar, not the bar's frosted output — the lens punched a saturated
///   hole through a pale capsule. The native bar renders plate and lens in one
///   pass; the nearest public equivalent is a thin material INSIDE the clear
///   lens (the "plate"), so what shows through is the bar's own frost.
/// - **Larger than the item, past the bar's capsule** by the same margin on
///   every side — a constant outset, never a scale (on a wide pill a
///   percentage grew the width four times as much as the height).
/// - **Late**: it follows the finger on a spring and stretches a little along
///   its travel. Driven here by a `CADisplayLink` towards the model pill.
///
/// The bar keeps its tinted pill as the MODEL — hit-tests, reveal and progress
/// all read it — and this view stands in for it: tinted glass at rest, clear
/// while lifted, settling when the bar reports the landing and the spring has
/// come to rest. It lives in the bar above the capsule's frame but beneath
/// the strip's titles where the host draws the glass, so the titles stay crisp
/// (glass blurs what is behind it; the native bar draws its items above its
/// lens too).
///
/// Not reproduced, and not reproducible with public API: the native lens's
/// chromatic rim and its magnification of the item — hit-testable over the
/// strip, `isInteractive` gave neither. They are its private material.
///
/// Instruments: `-selector-glass-lens-always` (never settle),
/// `-selector-glass-lens-frosted` (`.regular` while lifted),
/// `-selector-glass-lens-still` (no lift), `-selector-glass-lens-noplate`,
/// `-selector-glass-lens-thin` (a thin plate rather than ultra-thin).
@MainActor
final class SelectorGlassLens {
    static let isAskedFor = ProcessInfo.processInfo.arguments.contains("-selector-glass-lens")
    static let keepsLifted = ProcessInfo.processInfo.arguments.contains("-selector-glass-lens-always")
    private static let keepsFrosted = ProcessInfo.processInfo.arguments.contains("-selector-glass-lens-frosted")
    private static let liftsWithoutGrowth = ProcessInfo.processInfo.arguments.contains("-selector-glass-lens-still")
    private static let liftsWithoutPlate = ProcessInfo.processInfo.arguments.contains("-selector-glass-lens-noplate")
    private static let usesThinPlate = ProcessInfo.processInfo.arguments.contains("-selector-glass-lens-thin")

    /// The numbers the lift is cut to, read off the native tab bar.
    enum Lift {
        /// How far past the CAPSULE's edge the lifted lens stands, on every
        /// side. The pill rests `clearance` inside the capsule, so the lift
        /// grows it by `clearance + overhang` a side.
        static let overhang: CGFloat = 3
        static var outset: CGFloat { SelectorCapsuleMetrics.clearance + overhang }
        /// How far the lens stretches along its travel, per point/second of
        /// speed, and the most it may — small, it is what read as "too wide".
        static let stretchPerSpeed: CGFloat = 1 / 2400
        static let maximumStretch: CGFloat = 0.12
        /// The spring towards the model pill. Stiff enough to arrive within a
        /// beat, damped short of critical so a stop overshoots a touch.
        static let stiffness: CGFloat = 320
        static let dampingRatio: CGFloat = 0.74
        static let liftDuration: TimeInterval = 0.32
        static let settleDuration: TimeInterval = 0.36
        /// The lens settles anyway after this, for a host that never reports.
        static let landingFallback: TimeInterval = 1.2
    }

    /// The glass pill itself.
    let view: UIVisualEffectView
    /// Where the MODEL pill is, in the coordinate space `view` lives in.
    var modelFrame: () -> CGRect
    /// Whether the bar's progress says the pages have landed — asked every
    /// time the bar reports progress while a landing is awaited.
    private var isLanded: (() -> Bool)?
    /// Whether the bar still holds the pill (a finger down): no settling then.
    var isHeld: () -> Bool = { false }

    private(set) var isLifted = false
    private var mayRest = false
    private var fallback: Task<Void, Never>?
    private var link: CADisplayLink?
    private var centre: CGPoint = .zero
    private var velocity: CGPoint = .zero
    private var grow: CGFloat = 0
    private var lastTick: CFTimeInterval = 0
    private let tint: UIColor

    init(tint: UIColor, modelFrame: @escaping () -> CGRect) {
        self.tint = tint
        self.modelFrame = modelFrame
        view = UIVisualEffectView(effect: nil)
        view.effect = restingGlass()
        view.isUserInteractionEnabled = false
        // `cornerConfiguration`, not a layer radius: UIKit owns it and keeps it
        // through the effect's own transitions — see `InlineFilterTrayView`.
        view.cornerConfiguration = .capsule()
        if !Self.liftsWithoutPlate {
            // ⚠️ SHAPED LIKE THE LENS, BY A LAYER RADIUS. The glass's corner
            // configuration shapes the glass, not its content view, and a
            // BLUR effect view ignores `cornerConfiguration` altogether: both
            // ways the plate drew as a grey RECTANGLE behind a capsule pill —
            // filmed on For You's pill and on the editor's icon. A blur does
            // honour `clipsToBounds` + a layer radius, so the plate rounds
            // itself to a capsule on every layout.
            let plate = CapsulePlateView(effect: UIBlurEffect(
                style: Self.usesThinPlate ? .systemThinMaterial : .systemUltraThinMaterial
            ))
            plate.translatesAutoresizingMaskIntoConstraints = false
            plate.isUserInteractionEnabled = false
            view.contentView.addSubview(plate)
            NSLayoutConstraint.activate([
                plate.leadingAnchor.constraint(equalTo: view.contentView.leadingAnchor),
                plate.trailingAnchor.constraint(equalTo: view.contentView.trailingAnchor),
                plate.topAnchor.constraint(equalTo: view.contentView.topAnchor),
                plate.bottomAnchor.constraint(equalTo: view.contentView.bottomAnchor)
            ])
        }
    }

    private func restingGlass() -> UIGlassEffect {
        let effect = UIGlassEffect(style: .regular)
        effect.isInteractive = true
        effect.tintColor = tint
        return effect
    }

    private func liftedGlass() -> UIGlassEffect {
        let effect = UIGlassEffect(style: Self.keepsFrosted ? .regular : .clear)
        effect.isInteractive = true
        return effect
    }

    // MARK: Placing

    /// Puts the glass pill on the model pill — at rest exactly; while lifted
    /// only its visibility, since the spring owns its geometry then.
    func place(hidden: Bool = false) {
        let target = modelFrame()
        guard !hidden, target.width > 0, target.height > 0 else {
            view.isHidden = true
            return
        }
        view.isHidden = false
        // Bounds + centre rather than frame, so a change of size grows the
        // pill about its middle.
        if !isLifted {
            view.bounds = CGRect(origin: .zero, size: target.size)
            centre = CGPoint(x: target.midX, y: target.midY)
            view.center = centre
        }
    }

    // MARK: Lifting and settling

    /// The pill lifts: it was grabbed, or it is about to travel.
    func lift() {
        guard !isLifted else { return }
        isLifted = true
        centre = view.center
        velocity = .zero
        grow = 0
        startSpring()
        // The effect is ANIMATED into place, never faded in — a glass view's
        // alpha is the house rule the capsules already follow.
        UIView.animate(withDuration: Lift.liftDuration, delay: 0,
                       usingSpringWithDamping: 0.6, initialSpringVelocity: 0,
                       options: [.allowUserInteraction, .beginFromCurrentState]) {
            self.view.effect = self.liftedGlass()
        }
    }

    /// Keeps the lens lifted until `isLanded` says the pages have landed —
    /// and settles it anyway after a beat, for a host whose pager never
    /// reports. Asked at once as well: a finger let go ON a page reports no
    /// further progress.
    func awaitLanding(_ isLanded: @escaping () -> Bool) {
        guard isLifted else { return }
        self.isLanded = isLanded
        fallback?.cancel()
        fallback = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(Lift.landingFallback))
            guard !Task.isCancelled else { return }
            self?.settle()
        }
        noteProgress()
    }

    /// The bar reported progress: if the landing has arrived, the lens may
    /// rest as soon as its spring does.
    func noteProgress() {
        guard let isLanded, isLanded() else { return }
        self.isLanded = nil
        fallback?.cancel()
        fallback = nil
        mayRest = true
    }

    /// The pill lands: back to its tinted, resting size on the model pill.
    func settle() {
        isLanded = nil
        fallback?.cancel()
        fallback = nil
        guard isLifted, !Self.keepsLifted else { return }
        isLifted = false
        stopSpring()
        let rest = modelFrame()
        centre = CGPoint(x: rest.midX, y: rest.midY)
        grow = 0
        UIView.animate(withDuration: Lift.settleDuration, delay: 0,
                       usingSpringWithDamping: 0.7, initialSpringVelocity: 0,
                       options: [.allowUserInteraction, .beginFromCurrentState]) {
            self.view.effect = self.restingGlass()
            self.view.transform = .identity
            self.view.bounds = CGRect(origin: .zero, size: rest.size)
            self.view.center = self.centre
        }
    }

    /// The bar left its window: nothing to animate towards any more.
    func cancel() {
        isLanded = nil
        fallback?.cancel()
        fallback = nil
        stopSpring()
        isLifted = false
        view.transform = .identity
        view.effect = restingGlass()
        place()
    }

    // MARK: The spring

    private func startSpring() {
        guard link == nil else { return }
        mayRest = false
        lastTick = CACurrentMediaTime()
        let link = CADisplayLink(target: self, selector: #selector(tick))
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    private func stopSpring() {
        link?.invalidate()
        link = nil
    }

    @objc private func tick(_ link: CADisplayLink) {
        let now = link.timestamp
        let dt = CGFloat(min(max(now - lastTick, 1.0 / 240), 1.0 / 30))
        lastTick = now
        advance(by: dt)
    }

    /// One frame: the glass pill is pulled towards the model pill on a spring,
    /// grown past the capsule by the lift and stretched along its own
    /// velocity. Returns whether the pill is at rest on the model.
    @discardableResult
    func advance(by dt: CGFloat) -> Bool {
        let target = modelFrame()
        let goal = CGPoint(x: target.midX, y: target.midY)
        // A damped spring, integrated semi-implicitly.
        let damping = 2 * Lift.dampingRatio * sqrt(Lift.stiffness)
        let ax = Lift.stiffness * (goal.x - centre.x) - damping * velocity.x
        let ay = Lift.stiffness * (goal.y - centre.y) - damping * velocity.y
        velocity.x += ax * dt
        velocity.y += ay * dt
        centre.x += velocity.x * dt
        centre.y += velocity.y * dt

        // The lift: the pill grows past the capsule by a constant margin on
        // every side, eased in over a few frames.
        let wantedGrow = Self.liftsWithoutGrowth ? 0 : Lift.outset
        grow += (wantedGrow - grow) * min(1, dt * 16)
        view.bounds = CGRect(
            origin: .zero,
            size: CGSize(width: target.width + grow * 2, height: target.height + grow * 2)
        )
        view.center = centre
        // Stretch along the travel, thin across it — a drop, not a plate.
        let stretch = min(Lift.maximumStretch, abs(velocity.x) * Lift.stretchPerSpeed)
        view.transform = CGAffineTransform(scaleX: 1 + stretch, y: 1 - stretch * 0.4)

        // At rest, and allowed to rest: settle.
        let atRest = abs(goal.x - centre.x) < 0.5 && abs(velocity.x) < 8
        if atRest, mayRest, !isHeld() { settle() }
        return atRest
    }

    #if DEBUG
    /// Runs the spring to rest, frame by frame, as the display link would — a
    /// test has no run loop to wait on.
    func runSpringToRest() {
        for _ in 0..<600 where isLifted {
            if advance(by: 1 / 120) { break }
        }
    }
    #endif
}

/// A blur that keeps itself a capsule — see `SelectorGlassLens`'s plate.
private final class CapsulePlateView: UIVisualEffectView {
    override init(effect: UIVisualEffect?) {
        super.init(effect: effect)
        clipsToBounds = true
        layer.cornerCurve = .continuous
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func layoutSubviews() {
        super.layoutSubviews()
        layer.cornerRadius = min(bounds.width, bounds.height) / 2
    }
}
