import UIKit

/// The selection pill's GIVE. The bar keeps its pill as a MODEL — placed
/// exactly from progress every frame, hit-tested, read by tests — and this
/// draws the pill the viewer sees: the same flat tint, ON the model at every
/// moment (no lag: a spring that trailed the finger read as heavy, twice),
/// stretched along its travel by the model's speed and thinned across it,
/// like a drop with some give, and drawn a little towards the nearest item
/// as it passes. No glass: the native lens's material is private and a
/// spike (PR #182, closed) proved no public effect reads like it.
///
/// A `CADisplayLink` runs only while the stretch is easing back after the
/// model stops. A move that is not a travel — the bar's first layout, a
/// size change, new titles — SNAPS (`snapOnNextMove`), and so does every
/// move when Reduce Motion is on.
@MainActor
final class SelectorPillMotion {
    enum Tuning {
        /// How far the pill stretches along its travel per point/second of
        /// the model's speed, and the most it may — a bubble's give, not a
        /// smear.
        static let stretchPerSpeed: CGFloat = 1 / 3000
        static let maximumStretch: CGFloat = 0.08
        static let squashPerStretch: CGFloat = 0.4
        /// The speed the stretch is read from is smoothed over this long,
        /// and eases back to nothing over it once the model stops.
        static let speedSmoothing: CFTimeInterval = 0.06
        /// The magnet: within this distance of an item's centre the pill is
        /// drawn towards it, fully at the centre and not at all at the edge
        /// of the reach — a light click onto each item as the finger passes,
        /// on the pill the viewer sees only; what the pager is told is
        /// untouched.
        static let magnetReach: CGFloat = 14
        /// Slow enough to be at rest.
        static let restSpeed: CGFloat = 12
    }

    /// The pill the viewer sees. Lives beside the model in the same view.
    let body: UIView
    /// Where the MODEL pill is, in the space `body` lives in.
    var modelFrame: () -> CGRect
    /// The items' centres along x, in the same space — the magnet's detents.
    var detents: () -> [CGFloat] = { [] }
    /// Whether a move may animate at all: not off-window, not under Reduce
    /// Motion. A test overrides it to run the spring in a bare host.
    lazy var mayAnimate: () -> Bool = { [weak self] in
        self?.body.window != nil && !UIAccessibility.isReduceMotionEnabled
    }

    private var centre: CGPoint = .zero
    /// The model's speed along x, smoothed — what the stretch reads.
    private var speed: CGFloat = 0
    private var link: CADisplayLink?
    private var lastTick: CFTimeInterval = 0
    private var lastMove: CFTimeInterval = 0
    private var isPlaced = false
    private var snapsNextMove = false

    init(tint: UIColor, modelFrame: @escaping () -> CGRect) {
        self.modelFrame = modelFrame
        body = UIView()
        body.backgroundColor = tint
        body.isUserInteractionEnabled = false
        body.clipsToBounds = true
        body.layer.cornerCurve = .continuous
    }

    /// Whether the stretch is still easing back.
    var isMoving: Bool { link != nil }

    // MARK: Placing

    /// The model's moves until the current transaction commits are not a
    /// travel — a layout pass places it several times, one pass after
    /// another — so they land at once.
    ///
    /// ⚠️ **THE COMMIT, NOT THE NEXT MAIN-QUEUE HOP.** The layout this
    /// protects runs at the commit, in the run loop's before-waiting pass,
    /// and the main queue drains BEFORE that: called from a handler
    /// (`setTitles`, `didMoveToWindow`), the hop cleared the flag first and
    /// the layout's re-placement read as speed — a stretch and ease-back
    /// where the pill should have landed. `ZoomAnimator` measured the same
    /// ordering (`afterCurrentTransactionCommits`); this is its technique:
    /// an empty nested transaction's completion arrives only once the
    /// enclosing commit — layout included — has gone.
    func snapOnNextMove() {
        snapsNextMove = true
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in
            // Documented to arrive on the main thread.
            MainActor.assumeIsolated { self?.endSnapping() }
        }
        CATransaction.commit()
    }

    /// The layout is over: the next move is a travel again. (The commit
    /// calls this; a test, which does not run one, calls it by hand.)
    func endSnapping() { snapsNextMove = false }

    /// Where the body is drawn to: the model's centre, pulled towards the
    /// nearest item within the magnet's reach.
    private func goal(for model: CGRect) -> CGPoint {
        var goal = CGPoint(x: model.midX, y: model.midY)
        if let nearest = detents().min(by: { abs($0 - goal.x) < abs($1 - goal.x) }) {
            let distance = nearest - goal.x
            let hold = max(0, 1 - abs(distance) / Tuning.magnetReach)
            goal.x += distance * hold
        }
        return goal
    }

    /// Lands the body on its goal (the model, magnet included) and stops.
    func snap() {
        stop()
        let model = modelFrame()
        guard model.width > 0, model.height > 0 else { return }
        body.transform = .identity
        body.bounds = CGRect(origin: .zero, size: model.size)
        body.layer.cornerRadius = model.height / 2
        centre = goal(for: model)
        body.center = centre
        speed = 0
        lastMove = 0
        isPlaced = true
    }

    /// The model moved: the body goes with it, stretched by how fast — or
    /// lands plainly when nothing should animate.
    func modelMoved() {
        let model = modelFrame()
        guard model.width > 0, model.height > 0 else { return }
        // A hidden body does not stretch: the icon bar's pill, coming out of
        // neutral, appeared on the item it left rather than the one chosen.
        if !isPlaced || snapsNextMove || body.isHidden || !mayAnimate() {
            snap()
            return
        }
        body.bounds = CGRect(origin: .zero, size: model.size)
        body.layer.cornerRadius = model.height / 2
        let goal = goal(for: model)
        let now = CACurrentMediaTime()
        if lastMove > 0 {
            let dt = max(now - lastMove, 1.0 / 240)
            let instant = (goal.x - centre.x) / CGFloat(dt)
            let blend = CGFloat(min(1, dt / Tuning.speedSmoothing))
            speed += (instant - speed) * blend
        }
        lastMove = now
        centre = goal
        body.center = goal
        applyStretch()
        if abs(speed) >= Tuning.restSpeed { start() }
    }

    private func applyStretch() {
        let stretch = min(Tuning.maximumStretch, abs(speed) * Tuning.stretchPerSpeed)
        body.transform = CGAffineTransform(scaleX: 1 + stretch, y: 1 - stretch * Tuning.squashPerStretch)
    }

    func setHidden(_ hidden: Bool) { body.isHidden = hidden }

    /// The bar left its window: nothing to animate towards any more.
    func cancel() {
        stop()
        isPlaced = false
    }

    // MARK: The spring

    private func start() {
        lastTick = CACurrentMediaTime()
        guard link == nil else { return }
        let link = CADisplayLink(target: self, selector: #selector(tick))
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    private func stop() {
        link?.invalidate()
        link = nil
    }

    @objc private func tick(_ link: CADisplayLink) {
        let now = link.timestamp
        let dt = CGFloat(min(max(now - lastTick, 1.0 / 240), 1.0 / 30))
        lastTick = now
        if advance(by: dt) { snap() }
    }

    /// One frame with no move from the model: the speed the stretch reads
    /// eases back. Returns whether the pill is plain again.
    @discardableResult
    func advance(by dt: CGFloat) -> Bool {
        // The model may have moved without telling (a pass that skipped
        // `modelMoved`); it is the truth of where the body sits.
        let goal = goal(for: modelFrame())
        centre = goal
        body.center = goal
        speed *= exp(-dt / CGFloat(Tuning.speedSmoothing))
        applyStretch()
        return abs(speed) < Tuning.restSpeed
    }

    #if DEBUG
    /// Runs the stretch back to nothing frame by frame, as the display link
    /// would — a test has no run loop to wait on. Returns the frames it took.
    @discardableResult
    func runToRest(maximumFrames: Int = 600) -> Int {
        for frame in 0..<maximumFrames {
            if advance(by: 1 / 120) {
                snap()
                return frame + 1
            }
        }
        return maximumFrames
    }
    #endif
}
