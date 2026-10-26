import Metal
import QuartzCore
import UIKit

/// The pill the viewer sees on `PagedTabBar`: at rest the flat fill it has
/// always been, and under a finger the Liquid Glass lens of iOS 27's
/// `UISegmentedControl`, ported from the owner's `liquidglass` prototype
/// (`LiquidSegmentedControl`, #1748). The bar keeps its pill as a MODEL —
/// placed exactly from progress, hit-tested, read by tests — and this draws
/// what follows it.
///
/// **Dynamics, measured on the native control at 60 Hz by the prototype:**
/// - **Lift** on a press of the SELECTED segment (and on a tap elsewhere):
///   the lens grows 24×16pt past the pill on a critically damped spring
///   (stiffness 631.65, damping 50.27 — the native `liftSpring`), and the
///   fill fades in two layers: 70% after 20 ms with τ 65 ms, 30% with τ 50 ms.
/// - **Rest** 0.1 s after the release, never sooner than 0.19 s after the
///   lift; the fill returns 70% in ~150 ms, the last 30% from 250 ms.
/// - **Flex**, driven by the lens's ACCELERATION (`_UIFlexInteraction`):
///   1 + 0.19·tanh(a/2563) along the travel, 1 − 1.1·(that − 1) across it, a
///   drift of −13.1·tanh(a/3598) pt, the acceleration smoothed over two
///   94 ms stages.
/// - **Tap flight**: the lens lifts, leaves a frame later and slides on an
///   over-damped spring (k 905, ζ 1.41); the leading edge arrives fast, the
///   trailing one overshoots by the flex.
/// - **Held**: a stiff spring (k 700, ζ 0.95) under the finger.
/// - **Pages swiped**: the lens sits ON the model, flexing by the model's
///   own acceleration, read by finite differences.
///
/// Everything integrates in 4 ms sub-steps: the flex has to see the
/// acceleration impulse at a flight's start, which lasts ~15 ms.
///
/// **Rendering.** At rest — and whenever the glass cannot draw (shader still
/// compiling, Reduce Motion) — the pill is `body`, a plain view in the
/// strip, frame-driven (never a transform: it would scale the corner radius
/// into an ellipse). From the first moment of a lift to the moment the fill
/// is whole again, `body` hides and `glass` draws the lens; the real titles
/// under it are masked out of the row, and the shader redraws them through
/// the lens. A display link runs only while something moves.
@MainActor
final class SelectorLiquidLens {
    enum Tuning {
        /// How much the lifted lens outgrows the pill. ⚠️ THE TAB BAR'S LENS,
        /// not the segmented control's (owner, 2026-10-26, filmed on device):
        /// the native tab bar's lens is ~1.3× its pill's width and 20pt
        /// taller, standing well past the bar; the segmented control's
        /// 24×16pt read as a lens that "does not leave its container".
        static let growWidthRatio: CGFloat = 0.3
        static let minimumGrowWidth: CGFloat = 24
        static let growHeight: CGFloat = 20
        /// The titles seen through the lifted lens are magnified about its
        /// centre — the tab bar's lens reads its item ~1.15–1.2× larger.
        static let magnification: CGFloat = 1.15
        static func growWidth(forPillWidth width: CGFloat) -> CGFloat { max(minimumGrowWidth, width * growWidthRatio) }
        static let liftStiffness: CGFloat = 631.654682
        static let liftDamping: CGFloat = 50.265482
        static let releaseHang: CFTimeInterval = 0.10
        static let minimumLift: CFTimeInterval = 0.19
        static let slideDelay: CFTimeInterval = 0.016
        static let slideStiffness: CGFloat = 905
        static let slideDamping: CGFloat = 1.41
        /// A flight that does not lift (a programmatic selection): softer, no flex.
        static let flatStiffness: CGFloat = 400
        static let flatDamping: CGFloat = 0.85
        static let heldStiffness: CGFloat = 700
        static let heldDamping: CGFloat = 0.95
        static let widthStiffness: CGFloat = 500
        static let widthDamping: CGFloat = 0.9
        static let sizeStiffness: CGFloat = 628
        static let sizeDamping: CGFloat = 0.85
        static let flexMaxScale: CGFloat = 0.19
        static let flexMaxDrift: CGFloat = 13.1
        static let flexScaleAccel: CGFloat = 2563
        static let flexDriftAccel: CGFloat = 3598
        static let flexTransverse: CGFloat = 1.1
        static let flexSmoothing: CGFloat = 0.094
        static let flexResponse: CGFloat = 0.021
        static let flexVelocitySoftness: CGFloat = 3.4
        /// The native lens's optics, in points.
        static let portalAmount: CGFloat = 17.5
        static let portalReach: CGFloat = 11.2
        static let aberration: CGFloat = 2.316
        static let aberrationAngle: CGFloat = -.pi / 12
        static let aberrationBand: CGFloat = 8.8
        static let shadowOpacity: Float = 0.03
        static let shadowRadius: CGFloat = 8
        static let shadowOffsetY: CGFloat = 7
        /// How far the glass may draw beyond the capsule: the grown lens and its shadow.
        static let glassMargin: CGFloat = 40
    }

    /// What drives the lens's position right now.
    enum Mode: Equatable {
        /// On the model, flexing by its acceleration — pages swiped, layout.
        case following
        /// Under a finger: a stiff spring towards the model.
        case held
        /// Flying to the model on its own after a tap, a selection or a release.
        case flight(lifted: Bool)
    }

    /// The resting pill, in the strip beside the model.
    let body: UIView
    /// The lens, drawn over the bar IN ITS WINDOW while it shows.
    ///
    /// ⚠️ **Not a subview of the bar.** The lifted lens stands 8pt past the
    /// capsule's top and bottom, and the bar's hosts clip: the tab
    /// accessory's container cut the lens flat at its edges, on device. The
    /// window is the one ancestor that clips nothing the lens reaches.
    let glass: LiquidLensView
    /// The view the lens is drawn over (the bar): the glass covers its rect,
    /// grown by `Tuning.glassMargin`, in its window.
    weak var anchor: UIView?
    /// Where the MODEL pill is, in `space`.
    var modelFrame: () -> CGRect
    /// The strip the model lives in.
    weak var space: UIView?
    /// The titles the lens redraws and masks out — the segment row.
    weak var titles: UIView?
    /// The capsule, in `glass`'s space: the lens is clipped to it, grown.
    var capsuleFrame: () -> CGRect = { .zero }
    /// The resting fill.
    var tint: UIColor { didSet { body.backgroundColor = tint } }
    /// Whether a move may animate at all: not off-window, not under Reduce
    /// Motion. A test overrides it to run the springs in a bare host.
    lazy var mayAnimate: () -> Bool = { [weak self] in
        self?.body.window != nil && !MotionPreference.reducesMotion
    }
    /// Whether the glass may draw (the renderer's pipeline is compiled). A
    /// test overrides it to exercise the lens without a GPU frame.
    lazy var glassIsAvailable: () -> Bool = { LiquidLensRenderer.shared.isReady }

    private(set) var mode: Mode = .following
    // Position and size, in `space`.
    private var knobX: CGFloat = 0
    private var knobV: CGFloat = 0
    private var knobW: CGFloat = 0
    private var knobWV: CGFloat = 0
    private var knobY: CGFloat = 0
    private var knobH: CGFloat = 0
    private var sizeW: CGFloat = 0
    private var sizeH: CGFloat = 0
    private var sizeWV: CGFloat = 0
    private var sizeHV: CGFloat = 0
    // Lift.
    private var press: CGFloat = 0
    private var pressV: CGFloat = 0
    private var pressTarget: CGFloat = 0
    private var liftedSince: CFTimeInterval = 0
    private var restedSince: CFTimeInterval = 0
    private var restAt: CFTimeInterval?
    private var slideAt: CFTimeInterval?
    // The fill's two layers, and where each fade started.
    private var fillA: CGFloat = 1
    private var fillB: CGFloat = 1
    private var fillAAtLift: CGFloat = 1
    private var fillBAtLift: CGFloat = 1
    private var fillAAtRest: CGFloat = 1
    private var fillBAtRest: CGFloat = 1
    // Flex.
    private var flexScale: CGFloat = 1
    private var flexDrift: CGFloat = 0
    private var flexAccel: CGFloat = 0
    private var flexAccel1: CGFloat = 0
    // Following the model: finite differences.
    private var followAccel: CGFloat = 0
    private var lastFollow: CFTimeInterval?

    private var isPlaced = false
    private var snapsNextMove = false
    private var isRunning = false
    private var link: CADisplayLink?
    private var lastTick: CFTimeInterval = 0
    #if DEBUG
    /// A test's clock: when set, time is what `advance(by:)` says it is.
    var debugClock: CFTimeInterval?
    #endif

    // The titles' copy, and the mask that cuts the real ones out under the lens.
    /// The copy the next frame samples — one of two, alternated on every
    /// capture: the GPU may still be reading the last frame's when the
    /// selection crossfade asks for a new one, and rewriting it in place
    /// would tear that frame.
    private var overlay: MTLTexture?
    private var spareOverlay: MTLTexture?
    private var overlayIsStale = true
    /// The bitmap the titles are drawn into, kept between captures: a held
    /// drag redraws them every frame the selection crossfade moves.
    private var overlayPixels: [UInt8] = []
    private let titlesMask = CAShapeLayer()
    private let glassClip = CAShapeLayer()

    init(tint: UIColor, modelFrame: @escaping () -> CGRect) {
        self.tint = tint
        self.modelFrame = modelFrame
        body = UIView()
        body.backgroundColor = tint
        body.isUserInteractionEnabled = false
        body.clipsToBounds = true
        body.layer.cornerCurve = .continuous
        glass = LiquidLensView()
        glass.isHidden = true
        titlesMask.fillRule = .evenOdd
        titlesMask.fillColor = UIColor.black.cgColor
        glassClip.fillColor = UIColor.black.cgColor
        glass.layer.mask = glassClip
        LiquidLensRenderer.shared.prepare()
    }

    /// Whether anything is still moving (the display link runs).
    var isMoving: Bool { isRunning }
    /// Whether the lens is lifted, or on its way up or down.
    var isLifted: Bool { pressTarget > 0 }
    /// Whether the glass, not the flat pill, is what shows.
    var showsGlass: Bool { !glass.isHidden }
    /// The lens as drawn, in `space` — for tests and traces.
    private(set) var lensFrame: CGRect = .zero
    /// 0 at rest, 1 lifted.
    var liftProgress: CGFloat { press }
    /// 1 when the fill is whole, 0 when the lens is clear glass.
    var fillStrength: CGFloat { 0.7 * fillA + 0.3 * fillB }

    private func now() -> CFTimeInterval {
        #if DEBUG
        if let debugClock { return debugClock }
        #endif
        return CACurrentMediaTime()
    }

    // MARK: Placing

    /// The model's moves until the current transaction commits are not a
    /// travel (a layout places it several times), so they land at once — the
    /// same technique, and the same reason, as `SelectorPillMotion`'s.
    func snapOnNextMove() {
        snapsNextMove = true
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in
            MainActor.assumeIsolated { self?.endSnapping() }
        }
        CATransaction.commit()
    }

    func endSnapping() { snapsNextMove = false }

    /// Lands the lens on the model, still, keeping its lift.
    func snap() {
        let model = modelFrame()
        guard model.width > 0, model.height > 0 else { return }
        knobX = model.midX; knobW = model.width; knobY = model.midY; knobH = model.height
        knobV = 0; knobWV = 0
        flexScale = 1; flexDrift = 0; flexAccel = 0; flexAccel1 = 0; followAccel = 0
        sizeW = 0; sizeH = 0; sizeWV = 0; sizeHV = 0
        lastFollow = nil
        if case .following = mode {} else if !isLifted { mode = .following }
        isPlaced = true
        if !needsTicks { stop() }
        render()
    }

    /// The model moved.
    func modelMoved() {
        let model = modelFrame()
        guard model.width > 0, model.height > 0 else { return }
        knobY = model.midY
        knobH = model.height
        if !isPlaced || snapsNextMove || body.isHidden && glass.isHidden || !mayAnimate() {
            snap()
            return
        }
        switch mode {
        case .following:
            // A jump is not a travel: a host placing its pages in code (a
            // restore, a deep link) lands the pill, it does not fling it.
            guard abs(model.midX - knobX) <= max(24, model.width / 2) else {
                snap()
                return
            }
            // Finite differences: the flex reacts to what the pages impose,
            // with no spring lag on the position.
            let t = now()
            // A sample older than a few frames starts a new travel: the
            // pages were still in between.
            if let lastFollow, t - lastFollow < 0.1 {
                let dt = CGFloat(max(t - lastFollow, 1.0 / 240))
                let v = (model.midX - knobX) / dt
                followAccel = min(max((v - knobV) / dt, -150_000), 150_000)
                knobV = v
            } else {
                knobV = 0; followAccel = 0
            }
            lastFollow = t
            knobX = model.midX
            knobW = model.width
            knobWV = 0
            start()
            render()
        case .held, .flight:
            // The spring reads the model every frame.
            start()
        }
    }

    func setHidden(_ hidden: Bool) {
        body.isHidden = hidden
        if hidden { glass.isHidden = true; titles?.layer.mask = nil }
    }

    /// The bar left its window: nothing to animate towards any more.
    func cancel() {
        stop()
        glass.removeFromSuperview()
        pressTarget = 0; press = 0; pressV = 0; restAt = nil; slideAt = nil
        fillA = 1; fillB = 1
        mode = .following
        isPlaced = false
        showFlat()
    }

    // MARK: Gestures

    /// A finger went down on the selected segment's pill.
    func beginHold() {
        guard mayAnimate() else { return }
        endFollowing()
        restAt = nil
        slideAt = nil
        mode = .held
        lift()
        start()
    }

    /// The finger let go: the lens flies to wherever the model is (the bar
    /// has landed it) and rests 0.1 s later.
    func endHold() {
        guard case .held = mode else { return }
        mode = .flight(lifted: true)
        scheduleRest(after: Tuning.releaseHang, from: now())
        start()
    }

    /// A tap on another segment (`lifted`), or a selection made in code: the
    /// lens flies to the model on its own. Call it BEFORE the model moves.
    func fly(lifted: Bool) {
        guard isPlaced, mayAnimate() else { return }
        endFollowing()
        if lifted {
            let wasLifted = isLifted
            lift()
            mode = .flight(lifted: true)
            // Native: the lens lifts first and leaves one frame later.
            if !wasLifted { slideAt = liftedSince + Tuning.slideDelay }
            scheduleRest(after: Tuning.minimumLift, from: liftedSince)
        } else if case .held = mode {
            return
        } else {
            mode = .flight(lifted: isLifted)
        }
        start()
    }

    /// The titles changed under a lifted lens (the selection crossfade): its
    /// copy of them is redrawn before the next frame.
    func titlesChanged() {
        overlayIsStale = true
        if showsGlass { render() }
    }

    private func endFollowing() {
        if case .following = mode { knobV = 0; followAccel = 0; lastFollow = nil }
    }

    /// Rest → lifted: remembers when, and where each fill layer started
    /// from. A no-op when already lifted — restarting the fade from the
    /// values before the lift flashed the fill back for a frame (prototype).
    private func lift() {
        guard pressTarget == 0 else { return }
        pressTarget = 1
        liftedSince = now()
        fillAAtLift = fillA
        fillBAtLift = fillB
        overlayIsStale = true
    }

    private func scheduleRest(after delay: CFTimeInterval, from start: CFTimeInterval) {
        guard pressTarget > 0 else { restAt = nil; return }
        restAt = max(start + delay, liftedSince + Tuning.minimumLift)
    }

    // MARK: The clock

    private var needsTicks: Bool {
        if case .following = mode {
            return abs(flexScale - 1) > 0.002 || abs(flexDrift) > 0.05 || abs(followAccel) > 1 || abs(knobV) > 2
                || pressTarget > 0 || abs(press) > 0.002 || fillStrength < 0.995 || restAt != nil
        }
        return true
    }

    private func start() {
        guard !isRunning else { return }
        isRunning = true
        lastTick = now()
        #if DEBUG
        if debugClock != nil { return }
        #endif
        let link = CADisplayLink(target: self, selector: #selector(tick))
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    private func stop() {
        link?.invalidate()
        link = nil
        isRunning = false
    }

    @objc private func tick(_ link: CADisplayLink) {
        let t = now()
        let dt = CGFloat(min(max(t - lastTick, 1.0 / 240), 1.0 / 30))
        lastTick = t
        if step(dt) { stop() }
    }

    #if DEBUG
    /// One frame, on the test's clock. Returns whether everything has settled.
    @discardableResult
    func advance(by dt: CGFloat) -> Bool {
        debugClock = (debugClock ?? 0) + CFTimeInterval(dt)
        let settled = step(dt)
        if settled { stop() }
        return settled
    }

    /// Frames until everything settles, as the display link would run them.
    @discardableResult
    func runToRest(maximumFrames: Int = 600) -> Int {
        for frame in 0..<maximumFrames where advance(by: 1 / 120) {
            return frame + 1
        }
        return maximumFrames
    }
    #endif

    /// One frame of everything. Returns whether it all settled.
    private func step(_ dt: CGFloat) -> Bool {
        let t = now()
        let model = modelFrame()
        if model.width > 0 { knobY = model.midY; knobH = model.height }
        if let at = restAt, t >= at { pressTarget = 0; restAt = nil; restedSince = t; fillAAtRest = fillA; fillBAtRest = fillB }
        let sliding = slideAt.map { t >= $0 } ?? true
        if sliding { slideAt = nil }
        let targetX = sliding ? model.midX : knobX
        let targetW = sliding ? model.width : knobW

        let following: Bool
        let k: CGFloat
        let zeta: CGFloat
        switch mode {
        case .following: following = true; k = 0; zeta = 0
        case .held: following = false; k = Tuning.heldStiffness; zeta = Tuning.heldDamping
        case .flight(let lifted):
            following = false
            k = lifted ? Tuning.slideStiffness : Tuning.flatStiffness
            zeta = lifted ? Tuning.slideDamping : Tuning.flatDamping
        }
        let flexes: Bool = {
            if case .flight(lifted: false) = mode { return false }
            return true
        }()
        let c = 2 * sqrt(k) * zeta
        let cw = 2 * sqrt(Tuning.widthStiffness) * Tuning.widthDamping
        let cs = 2 * sqrt(Tuning.sizeStiffness) * Tuning.sizeDamping
        let steps = max(1, Int(ceil(dt / 0.004)))
        let h = dt / CGFloat(steps)
        for _ in 0..<steps {
            let a: CGFloat
            if following {
                followAccel *= exp(-h / 0.05)
                knobV *= exp(-h / 0.05)
                a = followAccel
            } else {
                a = k * (targetX - knobX) - c * knobV
                knobV += a * h
                knobX += knobV * h
                knobWV += (Tuning.widthStiffness * (targetW - knobW) - cw * knobWV) * h
                knobW += knobWV * h
            }
            pressV += (Tuning.liftStiffness * (pressTarget - press) - Tuning.liftDamping * pressV) * h
            press = min(max(press + pressV * h, 0), 1.2)
            flexAccel1 += ((flexes ? a : 0) - flexAccel1) * min(1, h / Tuning.flexSmoothing)
            flexAccel += (flexAccel1 - flexAccel) * min(1, h / Tuning.flexSmoothing)
            let direction = knobV / (abs(knobV) + Tuning.flexVelocitySoftness)
            let scaleTarget = 1 + Tuning.flexMaxScale * tanh(flexAccel * direction / Tuning.flexScaleAccel)
            let driftTarget = -Tuning.flexMaxDrift * tanh(flexAccel / Tuning.flexDriftAccel)
            flexScale += (scaleTarget - flexScale) * min(1, h / Tuning.flexResponse)
            flexDrift += (driftTarget - flexDrift) * min(1, h / Tuning.flexResponse)
            let (wT, hT) = targetSize()
            if sizeW > 0 {
                sizeWV += (Tuning.sizeStiffness * (wT - sizeW) - cs * sizeWV) * h; sizeW += sizeWV * h
                sizeHV += (Tuning.sizeStiffness * (hT - sizeH) - cs * sizeHV) * h; sizeH += sizeHV * h
            } else {
                sizeW = wT; sizeH = hT; sizeWV = 0; sizeHV = 0
            }
        }

        // The fill: analytic in time, not in frames (the first frame after a
        // tap can arrive 33 ms late).
        if pressTarget > 0 {
            let since = t - liftedSince
            fillA = fillAAtLift * (since < 0.02 ? 1 : CGFloat(exp(-(since - 0.02) / 0.065)))
            fillB = fillBAtLift * CGFloat(exp(-since / 0.05))
            fillAAtRest = fillA; fillBAtRest = fillB
            restedSince = t
        } else {
            let since = t - restedSince
            fillA = since < 0.04 ? fillAAtRest : 1 - (1 - fillAAtRest) * CGFloat(exp(-(since - 0.04) / 0.06))
            let sinceB = since - 0.25
            fillB = sinceB <= 0 ? fillBAtRest : 1 - (1 - fillBAtRest) * CGFloat(exp(-sinceB / 0.12))
        }

        let positionSettled: Bool = following
            ? abs(followAccel) < 1 && abs(knobV) < 2
            : abs(knobV) < 2 && abs(targetX - knobX) < 0.2 && abs(knobWV) < 2 && abs(targetW - knobW) < 0.2 && slideAt == nil
        let held: Bool = { if case .held = mode { return true }; return false }()
        let settled = positionSettled && !held
            && abs(pressTarget - press) < 0.002 && abs(pressV) < 0.02
            && abs(flexScale - 1) < 0.002 && abs(flexDrift) < 0.05 && abs(sizeWV) < 1 && abs(sizeHV) < 1
            && restAt == nil
            && (pressTarget > 0 ? fillB < 0.005 : fillB > 0.995 && fillA > 0.995)
        if settled {
            if !following { knobX = targetX; knobW = targetW }
            knobV = 0; knobWV = 0; followAccel = 0
            press = pressTarget; pressV = 0
            flexScale = 1; flexDrift = 0; flexAccel = 0; flexAccel1 = 0
            sizeWV = 0; sizeHV = 0
            if pressTarget == 0 { fillA = 1; fillB = 1 }
            if pressTarget == 0 { mode = .following }
        }
        render()
        return settled && pressTarget == 0
    }

    private func targetSize() -> (CGFloat, CGFloat) {
        let across = 1 - Tuning.flexTransverse * (flexScale - 1)
        return ((knobW + Tuning.growWidth(forPillWidth: knobW) * press) * flexScale, (knobH + Tuning.growHeight * press) * across)
    }

    // MARK: Drawing

    private func render() {
        guard isPlaced, knobW > 0, knobH > 0 else { return }
        let (wT, hT) = targetSize()
        let w = isRunning && sizeW > 0 ? sizeW : wT
        let h = isRunning && sizeH > 0 ? sizeH : hT
        let frame = CGRect(x: knobX + flexDrift - w / 2, y: knobY - h / 2, width: w, height: h)
        lensFrame = frame
        let wantsGlass = !body.isHidden || !glass.isHidden
        let glassy = wantsGlass && (press > 0.001 || pressTarget > 0 || fillStrength < 0.999) && glassIsAvailable()
        guard glassy, let space else {
            showFlat()
            body.frame = frame
            body.layer.cornerRadius = frame.height / 2
            return
        }
        body.isHidden = true
        glass.isHidden = false
        drawGlass(lens: frame, in: space)
    }

    private func showFlat() {
        if glass.isHidden == false || titles?.layer.mask === titlesMask {
            glass.isHidden = true
            if titles?.layer.mask === titlesMask { titles?.layer.mask = nil }
        }
        body.isHidden = false
    }

    private func drawGlass(lens: CGRect, in space: UIView) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if let anchor, let window = anchor.window {
            if glass.superview !== window { window.addSubview(glass) } else { window.bringSubviewToFront(glass) }
            let margin = Tuning.glassMargin
            glass.frame = anchor.convert(anchor.bounds, to: window).insetBy(dx: -margin, dy: -margin)
        }
        let inGlass = space.convert(lens, to: glass)
        // The lens may stand past the capsule (that is the lift), not past
        // the grown capsule.
        let capsule = capsuleFrame().insetBy(dx: -(lens.width / 2 + 2), dy: -(Tuning.growHeight / 2 + 2))
        glassClip.frame = glass.bounds
        glassClip.path = UIBezierPath(roundedRect: capsule, cornerRadius: capsule.height / 2).cgPath
        // The real titles under the lens are cut out; the shader redraws them.
        if let titles {
            let hole = space.convert(lens, to: titles)
            titlesMask.frame = titles.bounds
            let path = UIBezierPath(rect: titles.bounds.insetBy(dx: -40, dy: -40))
            path.append(UIBezierPath(roundedRect: hole, cornerRadius: min(hole.width, hole.height) / 2))
            titlesMask.path = path.cgPath
            if titles.layer.mask !== titlesMask { titles.layer.mask = titlesMask }
        }
        CATransaction.commit()

        let scale = max(1, glass.traitCollection.displayScale)
        if overlayIsStale { captureOverlay(scale: scale) }
        var u = LiquidLensRenderer.Uniforms()
        u.viewWidth = Float(glass.bounds.width * scale)
        u.viewHeight = Float(glass.bounds.height * scale)
        u.scale = Float(scale)
        u.centreX = Float(inGlass.midX * scale)
        u.centreY = Float(inGlass.midY * scale)
        u.halfWidth = Float(inGlass.width / 2 * scale)
        u.halfHeight = Float(inGlass.height / 2 * scale)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        tint.resolvedColor(with: body.traitCollection).getRed(&r, green: &g, blue: &b, alpha: &a)
        u.tintR = Float(r); u.tintG = Float(g); u.tintB = Float(b)
        u.tintA = Float(a * fillStrength)
        let lift = min(press, 1)
        u.outline = Float(lift)
        if let overlay, let titles {
            let origin = glass.convert(CGPoint.zero, to: titles)
            u.overlayEnabled = 1
            u.overlayWidth = Float(overlay.width)
            u.overlayHeight = Float(overlay.height)
            u.overlayOriginX = Float(origin.x * scale)
            u.overlayOriginY = Float(origin.y * scale)
            u.overlayAmount = Float(Tuning.portalAmount * lift * scale)
            u.magnification = Float(1 + (Tuning.magnification - 1) * lift)
            u.overlayReach = Float(Tuning.portalReach * scale)
            u.aberrationAmount = Float(Tuning.aberration * lift * scale)
            u.aberrationDirX = Float(cos(Tuning.aberrationAngle))
            u.aberrationDirY = Float(sin(Tuning.aberrationAngle))
            u.aberrationWidth = Float(Tuning.aberrationBand * scale)
        }
        u.shadowOpacity = Tuning.shadowOpacity * Float(lift)
        u.shadowRadius = Float(Tuning.shadowRadius * scale)
        u.shadowOffsetY = Float(Tuning.shadowOffsetY * scale)
        let margin = (Tuning.shadowRadius + Tuning.shadowOffsetY + 4) * scale
        u.quadMinX = Float(max(0, inGlass.minX * scale - margin))
        u.quadMinY = Float(max(0, inGlass.minY * scale - margin))
        u.quadMaxX = Float(min(glass.bounds.width * scale, inGlass.maxX * scale + margin))
        u.quadMaxY = Float(min(glass.bounds.height * scale, inGlass.maxY * scale + margin))
        glass.render(uniforms: u, overlay: overlay, scale: scale)
    }

    /// Draws the titles into the overlay texture, from the VIEWS.
    private func captureOverlay(scale: CGFloat) {
        guard let titles, titles.bounds.width > 0, titles.bounds.height > 0 else { return }
        overlayIsStale = false
        let width = Int(ceil(titles.bounds.width * scale))
        let height = Int(ceil(titles.bounds.height * scale))
        if spareOverlay?.width != width || spareOverlay?.height != height {
            spareOverlay = LiquidLensRenderer.shared.makeTexture(width: width, height: height)
        }
        guard let target = spareOverlay else { return }
        let bytesPerRow = width * 4
        if overlayPixels.count != bytesPerRow * height {
            overlayPixels = [UInt8](repeating: 0, count: bytesPerRow * height)
        }
        let drawn: Bool = overlayPixels.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: bytesPerRow, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue
            ) else { return false }
            context.clear(CGRect(x: 0, y: 0, width: width, height: height))
            // UIKit's top-left origin.
            context.translateBy(x: 0, y: CGFloat(height))
            context.scaleBy(x: scale, y: -scale)
            for child in titles.subviews {
                Self.draw(child, in: titles, into: context, alpha: 1)
            }
            return true
        }
        guard drawn else { return }
        overlayPixels.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else { return }
            target.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0,
                            withBytes: base, bytesPerRow: bytesPerRow)
        }
        spareOverlay = overlay
        overlay = target
    }

    /// Draws a view's leaves — labels in their resolved colour, template
    /// images tinted, filled backgrounds rounded — at the ancestors' combined
    /// alpha (the plain/semibold crossfade).
    ///
    /// ⚠️ NOT `layer.render(in:)`, and not `drawHierarchy` (spike #182). In a
    /// glass container UIKit draws a label as a WHITE MASK and colours it at
    /// composite time (adaptive vibrancy), so a render of the layer tree is
    /// white glyphs and a white badge; `drawHierarchy` from inside an effect
    /// view draws nothing, at 35 ms a frame. The views still know their
    /// colours; this draws from them.
    private static func draw(_ view: UIView, in root: UIView, into context: CGContext, alpha: CGFloat) {
        guard !view.isHidden, view.alpha > 0.01, !(view is UIVisualEffectView) else { return }
        let alpha = alpha * view.alpha
        let rect = root.convert(view.bounds, from: view)
        let traits = root.traitCollection
        if let fill = view.backgroundColor?.resolvedColor(with: traits), fill.cgColor.alpha > 0.01 {
            let radius = min(view.layer.cornerRadius, min(rect.width, rect.height) / 2)
            context.saveGState()
            context.setAlpha(alpha)
            context.setFillColor(fill.cgColor)
            context.addPath(UIBezierPath(roundedRect: rect, cornerRadius: radius).cgPath)
            context.fillPath()
            context.restoreGState()
        }
        // A gradient fill (a badge's `badgeGradient`) is a sublayer, not a
        // background colour; it holds no vibrant content, so it renders as is.
        for case let gradient as CAGradientLayer in view.layer.sublayers ?? [] where !gradient.isHidden {
            let frame = root.convert(gradient.frame, from: view)
            let radius = min(gradient.cornerRadius, min(frame.width, frame.height) / 2)
            context.saveGState()
            context.setAlpha(alpha * CGFloat(gradient.opacity))
            context.addPath(UIBezierPath(roundedRect: frame, cornerRadius: radius).cgPath)
            context.clip()
            context.translateBy(x: frame.minX, y: frame.minY)
            gradient.render(in: context)
            context.restoreGState()
        }
        if let label = view as? UILabel, let text = label.text, !text.isEmpty {
            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = label.textAlignment
            paragraph.lineBreakMode = label.lineBreakMode
            let attributes: [NSAttributedString.Key: Any] = [
                .font: label.font ?? UIFont.appFont(forTextStyle: .body),
                .foregroundColor: label.textColor.resolvedColor(with: traits),
                .paragraphStyle: paragraph
            ]
            let string = text as NSString
            let height = string.boundingRect(with: CGSize(width: rect.width, height: .greatestFiniteMagnitude),
                                             options: [.usesLineFragmentOrigin], attributes: attributes, context: nil).height
            let box = CGRect(x: rect.minX, y: rect.midY - height / 2, width: rect.width, height: height)
            context.saveGState()
            context.setAlpha(alpha)
            UIGraphicsPushContext(context)
            string.draw(with: box, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: attributes, context: nil)
            UIGraphicsPopContext()
            context.restoreGState()
        } else if let imageView = view as? UIImageView, var image = imageView.image {
            if let configuration = imageView.preferredSymbolConfiguration,
               let configured = image.applyingSymbolConfiguration(configuration) {
                image = configured
            }
            if image.renderingMode != .alwaysOriginal {
                // `.label`, not the view's `tintColor`: a glass container
                // recolours vibrant content to its backdrop (spike #182).
                image = image.withTintColor(UIColor.label.resolvedColor(with: traits), renderingMode: .alwaysOriginal)
            }
            let size = image.size
            guard size.width > 0, size.height > 0, rect.width > 0, rect.height > 0 else { return }
            let ratio = min(rect.width / size.width, rect.height / size.height, 1)
            let fitted = CGRect(x: rect.midX - size.width * ratio / 2, y: rect.midY - size.height * ratio / 2,
                                width: size.width * ratio, height: size.height * ratio)
            UIGraphicsPushContext(context)
            // The alpha goes in the call: `UIImage.draw(in:)` ignores the
            // context's `setAlpha`.
            image.draw(in: fitted, blendMode: .normal, alpha: alpha)
            UIGraphicsPopContext()
        }
        for child in view.subviews {
            draw(child, in: root, into: context, alpha: alpha)
        }
    }
}

/// The lens's surface: a transparent view backed by a `CAMetalLayer`, drawn
/// only when `SelectorLiquidLens` asks. Never hit-tested.
final class LiquidLensView: UIView {
    override class var layerClass: AnyClass { CAMetalLayer.self }
    private var metalLayer: CAMetalLayer { layer as! CAMetalLayer }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        backgroundColor = .clear
        isUserInteractionEnabled = false
        metalLayer.device = LiquidLensRenderer.shared.device
        metalLayer.pixelFormat = .bgra8Unorm
        metalLayer.framebufferOnly = true
        metalLayer.isOpaque = false
        metalLayer.presentsWithTransaction = true
        metalLayer.maximumDrawableCount = 3
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    #if DEBUG
    /// The last frame's inputs — what a test reads instead of pixels.
    private(set) var debugLastUniforms: LiquidLensRenderer.Uniforms?
    #endif

    func render(uniforms: LiquidLensRenderer.Uniforms, overlay: MTLTexture?, scale: CGFloat) {
        #if DEBUG
        debugLastUniforms = uniforms
        #endif
        metalLayer.contentsScale = scale
        let size = CGSize(width: max(1, bounds.width * scale), height: max(1, bounds.height * scale))
        if metalLayer.drawableSize != size { metalLayer.drawableSize = size }
        guard window != nil else { return }
        LiquidLensRenderer.shared.render(into: metalLayer, uniforms: uniforms, overlay: overlay)
    }
}
