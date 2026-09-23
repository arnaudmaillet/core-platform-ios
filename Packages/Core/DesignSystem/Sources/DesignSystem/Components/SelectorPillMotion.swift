import UIKit

/// The selection pill's WEIGHT. The bar keeps its pill as a MODEL — placed
/// exactly from progress every frame, hit-tested, read by tests — and this
/// draws the pill the viewer sees: the same flat tint, following the model
/// on a damped spring so it arrives a beat late and overshoots a touch, and
/// stretched along its travel by its own speed, thinned across it, like a
/// drop that is heavy rather than a plate that is pinned. No glass: the
/// native lens's material is private and a spike (PR #182, closed) proved
/// no public effect reads like it; its MOTION is what carried over here.
///
/// The spring runs on a `CADisplayLink` only while the pill is away from its
/// model; at rest the body sits exactly on the model and the link is gone.
/// A move that is not a travel — the bar's first layout, a size change, new
/// titles — SNAPS (`snapOnNextMove`), and so does every move when Reduce
/// Motion is on.
@MainActor
final class SelectorPillMotion {
    enum Tuning {
        /// Damped spring towards the model: stiff enough to arrive within a
        /// beat, damped short of critical so a stop overshoots a little.
        static let stiffness: CGFloat = 280
        static let dampingRatio: CGFloat = 0.72
        /// How far the pill stretches along its travel per point/second, and
        /// the most it may — a bubble's give, not a smear.
        static let stretchPerSpeed: CGFloat = 1 / 2400
        static let maximumStretch: CGFloat = 0.12
        static let squashPerStretch: CGFloat = 0.4
        /// Close enough, and slow enough, to be at rest.
        static let restDistance: CGFloat = 0.3
        static let restSpeed: CGFloat = 12
    }

    /// The pill the viewer sees. Lives beside the model in the same view.
    let body: UIView
    /// Where the MODEL pill is, in the space `body` lives in.
    var modelFrame: () -> CGRect
    /// Whether a move may animate at all: not off-window, not under Reduce
    /// Motion. A test overrides it to run the spring in a bare host.
    lazy var mayAnimate: () -> Bool = { [weak self] in
        self?.body.window != nil && !UIAccessibility.isReduceMotionEnabled
    }

    private var centre: CGPoint = .zero
    private var velocity: CGPoint = .zero
    private var link: CADisplayLink?
    private var lastTick: CFTimeInterval = 0
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

    /// Whether the body is on its way to the model.
    var isMoving: Bool { link != nil }

    // MARK: Placing

    /// The model's moves until the run loop turns are not a travel — a
    /// layout pass places it several times, one pass after another — so
    /// they land at once.
    func snapOnNextMove() {
        snapsNextMove = true
        DispatchQueue.main.async { [weak self] in self?.endSnapping() }
    }

    /// The layout is over: the next move is a travel again. (The run loop
    /// calls this; a test, which does not turn it, calls it by hand.)
    func endSnapping() { snapsNextMove = false }

    /// Lands the body exactly on the model and stops.
    func snap() {
        stop()
        let model = modelFrame()
        guard model.width > 0, model.height > 0 else { return }
        body.transform = .identity
        body.bounds = CGRect(origin: .zero, size: model.size)
        body.layer.cornerRadius = model.height / 2
        centre = CGPoint(x: model.midX, y: model.midY)
        body.center = centre
        velocity = .zero
        isPlaced = true
    }

    /// The model moved: the body sets off towards it — or lands on it at
    /// once when there is nothing to travel from.
    func modelMoved() {
        let model = modelFrame()
        guard model.width > 0, model.height > 0 else { return }
        // A hidden body does not travel: the icon bar's pill, coming out of
        // neutral, appeared on the item it left rather than the one chosen.
        if !isPlaced || snapsNextMove || body.isHidden || !mayAnimate() {
            snap()
            return
        }
        // The size follows at once; only the position lags.
        body.bounds = CGRect(origin: .zero, size: model.size)
        body.layer.cornerRadius = model.height / 2
        let goal = CGPoint(x: model.midX, y: model.midY)
        if abs(goal.x - centre.x) < Tuning.restDistance, abs(goal.y - centre.y) < Tuning.restDistance, link == nil {
            body.center = goal
            centre = goal
            return
        }
        start()
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

    /// One frame: the body is pulled towards the model on the spring and
    /// stretched by its speed. Returns whether it has come to rest on the
    /// model.
    @discardableResult
    func advance(by dt: CGFloat) -> Bool {
        let model = modelFrame()
        let goal = CGPoint(x: model.midX, y: model.midY)
        let damping = 2 * Tuning.dampingRatio * sqrt(Tuning.stiffness)
        let ax = Tuning.stiffness * (goal.x - centre.x) - damping * velocity.x
        let ay = Tuning.stiffness * (goal.y - centre.y) - damping * velocity.y
        velocity.x += ax * dt
        velocity.y += ay * dt
        centre.x += velocity.x * dt
        centre.y += velocity.y * dt
        body.center = centre
        let stretch = min(Tuning.maximumStretch, abs(velocity.x) * Tuning.stretchPerSpeed)
        body.transform = CGAffineTransform(scaleX: 1 + stretch, y: 1 - stretch * Tuning.squashPerStretch)
        return abs(goal.x - centre.x) < Tuning.restDistance && abs(goal.y - centre.y) < Tuning.restDistance
            && abs(velocity.x) < Tuning.restSpeed && abs(velocity.y) < Tuning.restSpeed
    }

    #if DEBUG
    /// Runs the spring to rest frame by frame, as the display link would — a
    /// test has no run loop to wait on. Returns the frames it took.
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
