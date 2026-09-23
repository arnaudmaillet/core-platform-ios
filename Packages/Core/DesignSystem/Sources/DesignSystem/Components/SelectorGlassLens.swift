import Metal
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
/// The native lens's optics — the item magnified, bent at the rim, with a
/// chromatic fringe — are its private material (a portal of the bar's own
/// content under a displacement map; no `UIGlassEffect` gives them). They
/// are rebuilt here over a bitmap of OUR strip: every frame while lifted the
/// lens captures the strip beneath it (`layer.render(in:)` of the bar's
/// content, a margin around), hands it to `LensRefractor`'s shader, and
/// shows the refracted copy inside the plate, under the glass rim. The REAL
/// titles inside the lens are cut out of the strip by an even-odd mask while
/// it is lifted, so only the copy shows there — otherwise the title sits on
/// its own magnified copy and doubles at the rim. The copy eases back to the
/// plain strip as the lens settles.
///
/// Instruments: `-selector-glass-lens-always` (never settle),
/// `-selector-glass-lens-frosted` (`.regular` while lifted),
/// `-selector-glass-lens-still` (no lift), `-selector-glass-lens-noplate`,
/// `-selector-glass-lens-thin` (a thin plate rather than ultra-thin),
/// `-selector-glass-lens-optics-off` (no refracted copy),
/// `-selector-glass-lens-trace` (capture + render cost, every second).
@MainActor
final class SelectorGlassLens {
    static let isAskedFor = ProcessInfo.processInfo.arguments.contains("-selector-glass-lens")
    static let keepsLifted = ProcessInfo.processInfo.arguments.contains("-selector-glass-lens-always")
    private static let keepsFrosted = ProcessInfo.processInfo.arguments.contains("-selector-glass-lens-frosted")
    private static let liftsWithoutGrowth = ProcessInfo.processInfo.arguments.contains("-selector-glass-lens-still")
    /// What fills the lifted lens behind the copy. NOTHING, by default: a
    /// `.clear` glass nested in the host's samples the RAW page, and that is
    /// exactly what the native `UISegmentedControl`'s lens shows — filmed in
    /// the tab accessory over a green page, its interior read 172,236,167
    /// against the control's frosted 197,220,251. The plates remain to
    /// compare (the tab BAR's lens reads as the bar's frost instead).
    /// `-selector-glass-lens-plate ultrathin|thin|glass|veil|none`;
    /// `-selector-glass-lens-noplate` and `-thin` still mean what they did.
    enum Plate: String { case ultrathin, thin, glass, veil, none }
    private static let plate: Plate = {
        let arguments = ProcessInfo.processInfo.arguments
        if let index = arguments.firstIndex(of: "-selector-glass-lens-plate"), index + 1 < arguments.count,
           let plate = Plate(rawValue: arguments[index + 1]) { return plate }
        if arguments.contains("-selector-glass-lens-noplate") { return .none }
        if arguments.contains("-selector-glass-lens-thin") { return .thin }
        // `.glass` by default: the user's reference is the native TAB BAR's
        // lens, whose interior is the bar's frost (the segmented control's
        // shows the raw page — two native lenses, two looks). Measured in
        // v9: a `.regular` plate reads 3% lighter than the bar beside it.
        return .glass
    }()
    private static let tracesOptics = ProcessInfo.processInfo.arguments.contains("-selector-glass-lens-trace")
    /// The copy refracts a SNAPSHOT of the page behind the bar too, frosted
    /// where the bar's glass covers it. It looks the part — the native lens
    /// refracts everything beneath it — but no capture is affordable:
    /// measured on For You's video grid, `drawHierarchy` 26–280 ms a call,
    /// `layer.render` 28 ms, a snapshot view rendered through CG blank; and a
    /// snapshot taken once per lift goes stale the moment the pages scroll
    /// under the bar. `-selector-glass-lens-backdrop` keeps it for comparison.
    static let refractsBackdrop = ProcessInfo.processInfo.arguments.contains("-selector-glass-lens-backdrop")
    private static let frostVeil: CGFloat = {
        let read = UserDefaults.standard.double(forKey: "lens-frost-veil")
        // 0.6 read lighter than the real frost beside the lens on For You
        // (242,239,207 against 223,211,171); 0.4 with a coarser blur is nearer.
        return read > 0 ? CGFloat(read) : 0.4
    }()

    /// The numbers the lift is cut to, read off the native tab bar.
    enum Lift {
        /// How far past the CAPSULE's edge the lifted lens stands, on every
        /// side. The pill rests `clearance` inside the capsule, so the lift
        /// grows it by `clearance + overhang` a side — 9pt, the native
        /// control's lens measured 8pt past its fill on the user's recording
        /// (fill 222×114 px → lens 270×162 px at 3x).
        static let overhang: CGFloat = 5
        static var outset: CGFloat { SelectorCapsuleMetrics.clearance + overhang }
        /// How much further it stands once it TRAVELS — the native lens is
        /// barely larger than the platter on a plain hold and well past the
        /// bar's edges once the finger moves or the item flies to a tap
        /// (filmed: ~1.36× the platter's height). `-lens-travel-overhang`.
        static let travelOverhang: CGFloat = {
            let read = UserDefaults.standard.double(forKey: "lens-travel-overhang")
            return read > 0 ? CGFloat(read) : 0
        }()
        /// How far the model pill must move from where it was grabbed before
        /// the hold counts as a travel.
        static let travelThreshold: CGFloat = 6
        /// How far the lens stretches along its travel, per point/second of
        /// speed, and the most it may — small, it is what read as "too wide".
        static let stretchPerSpeed: CGFloat = 1 / 2400
        static let maximumStretch: CGFloat = 0.12
        /// Flying to a TAP the native lens elongates hard — nearly across
        /// both segments — and lands within ~150 ms; under a finger it hardly
        /// stretches at all. Filmed on `UISegmentedControl`.
        static let maximumFlightStretch: CGFloat = 0.4
        /// The spring towards the model pill. Stiff enough to arrive within a
        /// beat, damped short of critical so a stop overshoots a touch; a
        /// flight to a tap is stiffer still.
        static let stiffness: CGFloat = 320
        static let flightStiffness: CGFloat = 640
        static let dampingRatio: CGFloat = 0.74
        static let flightDampingRatio: CGFloat = 0.85
        /// The flat pill turns to glass in ~150 ms and back in ~200 ms —
        /// filmed on `UISegmentedControl` (tap: glass at +150 ms, flat again
        /// ~200 ms after landing).
        static let liftDuration: TimeInterval = 0.15
        static let settleDuration: TimeInterval = 0.2
        /// The lens settles anyway after this, for a host that never reports.
        static let landingFallback: TimeInterval = 1.2
    }

    /// The glass pill itself — flat at rest (`fill`), glass while lifted.
    let view: UIVisualEffectView
    /// The resting indicator: a flat fill, the native segmented control's
    /// `_controlForegroundColor` (white in light, a grey in dark). Not glass:
    /// the native pill at rest is a plain fill, and only the lifted lens is
    /// glass. Dumped from a `UISegmentedControl` in the tab accessory.
    private let fill: CapsulePlateView
    /// ⚠️ Measured on the Phone app's "Tous / Manqués" control (the user's
    /// own recording, light): the fill reads 226 on a control at 247, a
    /// page at 254 — a translucent DARK fill, `secondarySystemFill`
    /// (120,120,128 at 16% → 226 over 247). A white fill, what the same
    /// control dumped in the tab accessory, vanished on a white toolbar.
    static let restingFill = UIColor.secondarySystemFill
    /// Where the MODEL pill is, in the coordinate space `view` lives in.
    var modelFrame: () -> CGRect
    /// Whether the bar's progress says the pages have landed — asked every
    /// time the bar reports progress while a landing is awaited.
    private var isLanded: (() -> Bool)?
    /// Whether the bar still holds the pill (a finger down): no settling then.
    var isHeld: () -> Bool = { false }
    /// The bar's strip — the view holding the titles or icons the lens shows
    /// a refracted copy of. Converted through `view.superview`, so it may
    /// live in any space (the bars keep it inside a scroll view).
    var source: () -> UIView? = { nil }
    /// The bar's visible glass, in the bar's space (a platter reaches past
    /// the bar) — where the backdrop is frosted.
    var capsuleFrame: () -> CGRect = { .zero }

    private(set) var isLifted = false
    private var mayRest = false
    private var fallback: Task<Void, Never>?
    private var link: CADisplayLink?
    private var centre: CGPoint = .zero
    private var velocity: CGPoint = .zero
    private var grow: CGFloat = 0
    /// 0 on a plain hold, 1 while travelling (the finger moved, or the pill
    /// flies to a tap): the native lens grows and magnifies more then.
    private var zoom: CGFloat = 0
    private var liftOrigin: CGPoint = .zero
    private var lastTick: CFTimeInterval = 0
    private let tint: UIColor

    // The optics: the refracted copy of the strip, its source, and the mask
    // that cuts the real titles out of the strip beneath it.
    private let copy: LensCopyView?
    private let optics = LensRefractor.Optics.fromArguments()
    private var sourceTexture: MTLTexture?
    private var sourceBytes: [UInt8] = []
    private var sourceMask: CAShapeLayer?
    private weak var maskedLayer: CALayer?
    /// When the settle began, while the copy eases back to the plain strip.
    private var settleStarted: CFTimeInterval?
    /// The page behind the bar, snapshotted once per quarter second over the
    /// whole bar and a margin — `drawHierarchy` costs ~10 ms a call, and the
    /// page under a held finger does not change.
    private var backdrop: (raw: UIImage, coarse: UIImage, regionInPage: CGRect, taken: CFTimeInterval, page: ObjectIdentifier)?
    private static let backdropRefresh: CFTimeInterval = 0.25
    private var traceCost: (frames: Int, capture: Double, render: Double, since: CFTimeInterval) = (0, 0, 0, 0)
    #if DEBUG
    private var traceMotion: (frames: Int, held: Int, maxStretch: CGFloat, maxSpeed: CGFloat, wasHeld: Bool) = (0, 0, 0, 0, false)
    private var traceSnapshots = 0
    private var dumped = false
    private var dumpPending = false
    #endif

    init(tint: UIColor, modelFrame: @escaping () -> CGRect) {
        self.tint = tint
        self.modelFrame = modelFrame
        if LensRefractor.isSwitchedOff || LensRefractor.shared.device == nil {
            copy = nil
        } else {
            LensRefractor.shared.prepare()
            copy = LensCopyView(device: LensRefractor.shared.device)
        }
        view = UIVisualEffectView(effect: nil)
        view.isUserInteractionEnabled = false
        fill = CapsulePlateView(effect: nil)
        fill.backgroundColor = Self.restingFill
        // `cornerConfiguration`, not a layer radius: UIKit owns it and keeps it
        // through the effect's own transitions — see `InlineFilterTrayView`.
        view.cornerConfiguration = .capsule()
        for plate in [Self.makePlate(), fill].compactMap({ $0 }) {
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
        // ⚠️ The copy is NOT in the glass's contentView: a glass effect view
        // treats its content (adaptive vibrancy), and the copy came out
        // washed — its darkest glyph pixel at 105/255 against 0 for the real
        // title, measured on film. It stands beside the glass in the bar, just
        // above it, placed with it every frame (`refract`).
        copy?.isHidden = true
    }

    /// ⚠️ SHAPED LIKE THE LENS, BY A LAYER RADIUS. The glass's corner
    /// configuration shapes the glass, not its content view, and a BLUR
    /// effect view ignores `cornerConfiguration` altogether: both ways the
    /// plate drew as a grey RECTANGLE behind a capsule pill — filmed on For
    /// You's pill and on the editor's icon. A blur does honour `clipsToBounds`
    /// + a layer radius, so the plate rounds itself to a capsule on every
    /// layout.
    private static func makePlate() -> UIView? {
        switch plate {
        case .none: return nil
        case .ultrathin: return CapsulePlateView(effect: UIBlurEffect(style: .systemUltraThinMaterial))
        case .thin: return CapsulePlateView(effect: UIBlurEffect(style: .systemThinMaterial))
        case .glass:
            let effect = UIGlassEffect(style: .regular)
            effect.isInteractive = false
            return CapsulePlateView(effect: effect)
        case .veil:
            let veil = CapsulePlateView(effect: nil)
            veil.backgroundColor = UIColor.systemBackground.withAlphaComponent(0.35)
            return veil
        }
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
        settleStarted = nil
        centre = view.center
        velocity = .zero
        grow = 0
        zoom = 0
        liftOrigin = CGPoint(x: modelFrame().midX, y: modelFrame().midY)
        startSpring()
        // The effect is ANIMATED into place, never faded in — a glass view's
        // alpha is the house rule the capsules already follow.
        UIView.animate(withDuration: Lift.liftDuration, delay: 0,
                       options: [.allowUserInteraction, .beginFromCurrentState, .curveEaseOut]) {
            self.view.effect = self.liftedGlass()
            self.fill.alpha = 0
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
        // The copy eases back to the plain strip over the settle, frame by
        // frame off the glass's presentation; the link stays for that.
        if copy?.isHidden == false {
            settleStarted = CACurrentMediaTime()
        } else {
            stopSpring()
            hideCopy()
        }
        let rest = modelFrame()
        centre = CGPoint(x: rest.midX, y: rest.midY)
        grow = 0
        UIView.animate(withDuration: Lift.settleDuration, delay: 0,
                       options: [.allowUserInteraction, .beginFromCurrentState, .curveEaseOut]) {
            self.view.effect = nil
            self.fill.alpha = 1
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
        hideCopy()
        isLifted = false
        settleStarted = nil
        view.transform = .identity
        view.effect = nil
        fill.alpha = 1
        place()
    }

    // MARK: The spring

    private func startSpring() {
        mayRest = false
        lastTick = CACurrentMediaTime()
        guard link == nil else { return }
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
        if isLifted {
            advance(by: dt)
        } else if settleStarted != nil {
            advanceSettle(at: now)
        } else {
            stopSpring()
        }
    }

    /// One frame: the glass pill is pulled towards the model pill on a spring,
    /// grown past the capsule by the lift and stretched along its own
    /// velocity. Returns whether the pill is at rest on the model.
    @discardableResult
    func advance(by dt: CGFloat) -> Bool {
        let target = modelFrame()
        let goal = CGPoint(x: target.midX, y: target.midY)
        // A damped spring, integrated semi-implicitly — stiffer for a flight
        // to a tap than under a finger.
        let held = isHeld()
        let stiffness = held ? Lift.stiffness : Lift.flightStiffness
        let damping = 2 * (held ? Lift.dampingRatio : Lift.flightDampingRatio) * sqrt(stiffness)
        let ax = stiffness * (goal.x - centre.x) - damping * velocity.x
        let ay = stiffness * (goal.y - centre.y) - damping * velocity.y
        velocity.x += ax * dt
        velocity.y += ay * dt
        centre.x += velocity.x * dt
        centre.y += velocity.y * dt

        // Travelling: a tap sends the pill flying (not held), or the finger
        // has moved it past the threshold. The zoom eases in over ~0.1 s and
        // stays for the rest of the lift — the native lens keeps its travel
        // size once the finger has moved, until it lifts.
        let travelling = !isHeld() || abs(goal.x - liftOrigin.x) > Lift.travelThreshold
            || abs(goal.y - liftOrigin.y) > Lift.travelThreshold
        if travelling { zoom += (1 - zoom) * min(1, dt * 10) }

        // The lift: the pill grows past the capsule by a constant margin on
        // every side, eased in over a few frames, and further while it
        // travels.
        let wantedGrow = Self.liftsWithoutGrowth ? 0 : Lift.outset + Lift.travelOverhang * zoom
        grow += (wantedGrow - grow) * min(1, dt * 16)
        view.bounds = CGRect(
            origin: .zero,
            size: CGSize(width: target.width + grow * 2, height: target.height + grow * 2)
        )
        view.center = centre
        // Stretch along the travel, thin across it — a drop, not a plate.
        let stretch = min(held ? Lift.maximumStretch : Lift.maximumFlightStretch,
                          abs(velocity.x) * Lift.stretchPerSpeed)
        view.transform = CGAffineTransform(scaleX: 1 + stretch, y: 1 - stretch * 0.4)
        #if DEBUG
        if Self.tracesOptics {
            traceMotion.frames += 1
            if held { traceMotion.held += 1 }
            traceMotion.maxStretch = max(traceMotion.maxStretch, stretch)
            traceMotion.maxSpeed = max(traceMotion.maxSpeed, abs(velocity.x))
            if held != traceMotion.wasHeld {
                print(String(format: "[SelectorGlassLens] held → %d at goal %.0f, centre %.0f, v %.0f", held ? 1 : 0, goal.x, centre.x, velocity.x))
                traceMotion.wasHeld = held
            }
        }
        #endif

        // The copy of the strip, magnified and bent in step with the lift.
        refract(lift: Lift.outset > 0 ? grow / Lift.outset : 1, zoom: zoom,
                box: CGRect(x: centre.x - view.bounds.width / 2, y: centre.y - view.bounds.height / 2,
                            width: view.bounds.width, height: view.bounds.height),
                transform: view.transform,
                hole: view.superview.map { $0.convert(view.bounds, from: view) })

        // At rest, and allowed to rest: settle.
        let atRest = abs(goal.x - centre.x) < 0.5 && abs(velocity.x) < 8
        if atRest, mayRest, !isHeld() { settle() }
        return atRest
    }

    /// One frame of the settle: the copy follows the glass's presentation
    /// frame as it shrinks and eases back to the plain strip; at the end the
    /// real titles come back.
    private func advanceSettle(at now: CFTimeInterval) {
        guard let settleStarted else { return }
        let elapsed = now - settleStarted
        guard elapsed < Lift.settleDuration else {
            self.settleStarted = nil
            stopSpring()
            hideCopy()
            return
        }
        let remaining = CGFloat(1 - elapsed / Lift.settleDuration)
        let presented = view.layer.presentation()?.frame ?? view.frame
        refract(lift: remaining * remaining, zoom: zoom * remaining, box: presented, transform: .identity, hole: presented)
    }

    // MARK: The optics

    /// Captures the strip under the lens's `box` (the bar's space, before
    /// `transform` — the glass's stretch, which the copy takes on too), cuts
    /// the real titles out of the strip within `hole` (the bar's space, the
    /// glass as it shows), and renders the refracted copy at `lift` (0: the
    /// plain strip, 1: magnified and bent as on a hold) and `zoom` (1: as
    /// while travelling, the stronger magnification).
    private func refract(lift: CGFloat, zoom: CGFloat, box: CGRect, transform: CGAffineTransform, hole: CGRect?) {
        guard let copy, let bar = view.superview, let content = source() else { return }
        if copy.superview !== bar { bar.insertSubview(copy, aboveSubview: view) }
        let refractor = LensRefractor.shared
        guard refractor.isReady, box.width > 0, box.height > 0 else {
            hideCopy()
            return
        }
        let scale = max(1, view.window?.screen.scale ?? view.traitCollection.displayScale)
        let lift = Float(max(0, min(1, lift)))
        let zoom = Float(max(0, min(1, zoom)))
        // A hold magnifies a little, a travel a lot — both read off the
        // native lens (1.15× held, 1.4× dragging).
        let held = 1 + (optics.magnification - 1) * lift
        let magnification = held + (optics.travelMagnification - optics.magnification) * zoom * lift
        // Captured as fine as the copy will show it, so a 1.4× title is a
        // title, not a 3× bitmap blown up soft.
        let captureScale = scale * CGFloat(magnification)
        let margin = LensRefractor.Optics.captureMargin
        let region = box.insetBy(dx: -margin, dy: -margin)
        let width = Int(ceil(region.width * captureScale)), height = Int(ceil(region.height * captureScale))
        let started = Self.tracesOptics ? CACurrentMediaTime() : 0
        guard let texture = sourceTexture(width: width, height: height),
              capture(content, region: content.convert(region, from: bar), scale: captureScale, into: texture) else {
            hideCopy()
            return
        }
        let captured = Self.tracesOptics ? CACurrentMediaTime() : 0
        if let hole { maskSource(content, hole: content.convert(hole, from: bar)) }

        copy.isHidden = false
        copy.transform = .identity
        copy.bounds = CGRect(origin: .zero, size: box.size)
        copy.center = CGPoint(x: box.midX, y: box.midY)
        copy.transform = transform
        let layer = copy.metalLayer
        layer.contentsScale = scale
        let size = SIMD2<Float>(Float(box.width * scale), Float(box.height * scale))
        layer.drawableSize = CGSize(width: CGFloat(size.x), height: CGFloat(size.y))
        // The bend may reach a little past the lens's own edge: at the rim the
        // magnified sample sits r/mag from the centre, and the native lens
        // shows the neighbouring item's edge pulled in there (the "M" of
        // Messages inside the held For You lens, filmed). ⚠️ At 10pt it read
        // the editor's neighbouring icons 2pt past the rim, split into
        // colours. ⚠️ NOT doubled while travelling: with 24pt over a 16pt
        // edge, "35 Followers" read as "35 F" folded small at the rim.
        let bend = optics.bend * Float(scale) * lift
        #if DEBUG
        debugMagnification = CGFloat(magnification)
        #endif
        let uniforms = LensRefractor.Uniforms(
            size: size,
            centre: size / 2,
            halfExtent: size / 2,
            sourceOffset: SIMD2(repeating: Float(margin * captureScale)),
            sourceSize: SIMD2(Float(width), Float(height)),
            magnification: magnification,
            edge: optics.edge * Float(scale),
            bend: bend,
            aberration: optics.aberration,
            blur: optics.blur * Float(scale) * lift,
            sourceScale: Float(captureScale / scale)
        )
        refractor.render(source: texture, into: layer, uniforms: uniforms)
        if Self.tracesOptics {
            trace(capture: captured - started, render: CACurrentMediaTime() - captured)
        }
        #if DEBUG
        if dumpPending, let target = refractor.makeTargetTexture(width: Int(size.x), height: Int(size.y)),
           refractor.render(source: texture, into: target, uniforms: uniforms) {
            dumpPending = false
            var bytes = [UInt8](repeating: 0, count: target.width * target.height * 4)
            target.getBytes(&bytes, bytesPerRow: target.width * 4,
                            from: MTLRegionMake2D(0, 0, target.width, target.height), mipmapLevel: 0)
            if let context = CGContext(data: &bytes, width: target.width, height: target.height, bitsPerComponent: 8,
                                       bytesPerRow: target.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                       bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
               let image = context.makeImage() {
                let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("lens-copy.png")
                try? UIImage(cgImage: image).pngData()?.write(to: url)
                print(String(format: "[SelectorGlassLens] copy dumped (lift %.2f, mag %.3f, copy alpha %.2f, hidden %d) to %@",
                             lift, uniforms.magnification, copy.alpha, copy.isHidden ? 1 : 0, url.path))
            }
        }
        #endif
    }

    private func sourceTexture(width: Int, height: Int) -> MTLTexture? {
        if let sourceTexture, sourceTexture.width == width, sourceTexture.height == height { return sourceTexture }
        sourceTexture = LensRefractor.shared.makeSourceTexture(width: width, height: height)
        return sourceTexture
    }

    /// Draws `region` of the strip (its own space) into the texture, at
    /// `scale`, top row first — UIKit's orientation, flipped for a bitmap
    /// context. The strip's mask does not apply: the copy is drawn from the
    /// views, not from the layer tree.
    private func capture(_ content: UIView, region: CGRect, scale: CGFloat, into texture: MTLTexture) -> Bool {
        let width = texture.width, height = texture.height, bytesPerRow = width * 4
        if sourceBytes.count != bytesPerRow * height {
            sourceBytes = [UInt8](repeating: 0, count: bytesPerRow * height)
        }
        let drawn = sourceBytes.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(
                data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
            ) else { return false }
            context.clear(CGRect(x: 0, y: 0, width: width, height: height))
            context.translateBy(x: 0, y: CGFloat(height))
            context.scaleBy(x: scale, y: -scale)
            context.translateBy(x: -region.minX, y: -region.minY)
            if let bar = view.superview {
                if Self.refractsBackdrop {
                    drawBackdrop(into: context, region: region, content: content, bar: bar)
                } else {
                    // The bar's glass EDGE, so the rim has it to bend: the host's
                    // frost reads a few levels darker than a white page (247
                    // against 254 on the user's recording, 3%) and lighter than
                    // a dark one. A translucent `label` veil over the capsule
                    // gives that boundary to the copy; the clear glass beneath
                    // shows the live page itself, unrefracted.
                    let capsule = content.convert(capsuleFrame(), from: bar)
                    context.saveGState()
                    context.setFillColor(UIColor.label.resolvedColor(with: content.traitCollection).withAlphaComponent(0.035).cgColor)
                    context.addPath(UIBezierPath(roundedRect: capsule, cornerRadius: min(capsule.width, capsule.height) / 2).cgPath)
                    context.fillPath()
                    context.restoreGState()
                }
            }
            Self.draw(content, in: content, into: context, alpha: 1)
            #if DEBUG
            if Self.tracesOptics, !dumped, traceCost.frames >= 5, let image = context.makeImage() {
                // The fifth captured frame of the first lift, as a file, to
                // read what the copy is of; `refract` dumps the copy with it.
                dumped = true
                dumpPending = true
                let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("lens-source.png")
                try? UIImage(cgImage: image).pngData()?.write(to: url)
                print("[SelectorGlassLens] source dumped to \(url.path)")
            }
            #endif
            return true
        }
        guard drawn else { return false }
        sourceBytes.withUnsafeBytes { raw in
            texture.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0,
                            withBytes: raw.baseAddress!, bytesPerRow: bytesPerRow)
        }
        return true
    }

    /// The page behind the bar, as it shows: raw where the lens overhangs the
    /// bar's glass, frosted (blurred by downsampling, veiled towards
    /// `secondarySystemBackground`) inside the capsule — an emulation of the
    /// host's regular glass, which no API lets us sample. Snapshot with
    /// `drawHierarchy(afterScreenUpdates: false)` of the PAGE view only (the
    /// tab's or the navigation stack's top view), never of a view holding
    /// this lens: that would feed the copy back into itself.
    private func drawBackdrop(into context: CGContext, region: CGRect, content: UIView, bar: UIView) {
        guard let page = Self.pageView(behind: bar), !bar.isDescendant(of: page), page.window != nil else { return }
        let now = CACurrentMediaTime()
        let neededInPage = page.convert(region, from: content)
        if let cached = backdrop, cached.page == ObjectIdentifier(page),
           now - cached.taken < Self.backdropRefresh, cached.regionInPage.contains(neededInPage) {
            // still good
        } else {
            // The whole bar plus the lens's reach, so a drag along it needs
            // no new snapshot.
            let reach = Lift.outset + Lift.travelOverhang + LensRefractor.Optics.captureMargin
            let barInPage = page.convert(bar.bounds.insetBy(dx: -reach - 40, dy: -reach), from: bar)
            let regionInPage = barInPage.union(neededInPage)
            guard regionInPage.width > 0, regionInPage.height > 0 else { return }
            // 1× is plenty for the raw page; the frost comes from an 8× coarser copy.
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            let raw = UIGraphicsImageRenderer(size: regionInPage.size, format: format).image { rendererContext in
                rendererContext.cgContext.translateBy(x: -regionInPage.minX, y: -regionInPage.minY)
                page.drawHierarchy(in: page.bounds, afterScreenUpdates: false)
            }
            let coarseSize = CGSize(width: max(2, regionInPage.width / 12), height: max(2, regionInPage.height / 12))
            let coarse = UIGraphicsImageRenderer(size: coarseSize, format: format).image { _ in
                raw.draw(in: CGRect(origin: .zero, size: coarseSize))
            }
            backdrop = (raw, coarse, regionInPage, now, ObjectIdentifier(page))
            #if DEBUG
            traceSnapshots += 1
            if Self.tracesOptics, traceSnapshots <= 3 {
                print(String(format: "[SelectorGlassLens] backdrop snapshot #%d of %@ %.0fx%.0f in %.1f ms", traceSnapshots,
                             String(describing: type(of: page)), regionInPage.width, regionInPage.height, (CACurrentMediaTime() - now) * 1000))
            }
            #endif
        }
        guard let backdrop else { return }
        let placed = content.convert(backdrop.regionInPage, from: page)
        let capsule = content.convert(capsuleFrame(), from: bar)
        let veil = UIColor.secondarySystemBackground.resolvedColor(with: content.traitCollection)
        UIGraphicsPushContext(context)
        backdrop.raw.draw(in: placed)
        context.saveGState()
        context.addPath(UIBezierPath(roundedRect: capsule, cornerRadius: min(capsule.width, capsule.height) / 2).cgPath)
        context.clip()
        context.interpolationQuality = .high
        backdrop.coarse.draw(in: placed)
        context.setFillColor(veil.withAlphaComponent(Self.frostVeil).cgColor)
        context.fill(capsule)
        context.restoreGState()
        UIGraphicsPopContext()
    }

    /// The page a bar sits over: the selected tab's top view for a bar in a
    /// tab accessory, the navigation stack's top view for a bar in a toolbar.
    private static func pageView(behind bar: UIView) -> UIView? {
        var responder: UIResponder? = bar
        while let current = responder {
            if let tabs = current as? UITabBarController {
                let selected = tabs.selectedViewController
                return ((selected as? UINavigationController)?.topViewController ?? selected)?.view
            }
            if let navigation = current as? UINavigationController {
                return navigation.topViewController?.view
            }
            responder = current.next
        }
        return nil
    }

    /// The strip shows everywhere but inside `hole` (its own space), where
    /// the copy stands in for it.
    private func maskSource(_ content: UIView, hole: CGRect) {
        let mask: CAShapeLayer
        if let sourceMask {
            mask = sourceMask
        } else {
            mask = CAShapeLayer()
            mask.fillRule = .evenOdd
            sourceMask = mask
        }
        if content.layer.mask !== mask {
            content.layer.mask = mask
            maskedLayer = content.layer
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        mask.frame = content.layer.bounds
        let path = UIBezierPath(rect: content.bounds)
        path.append(UIBezierPath(roundedRect: hole, cornerRadius: min(hole.width, hole.height) / 2))
        mask.path = path.cgPath
        CATransaction.commit()
    }

    /// Draws the strip's leaves — labels in their resolved colour, images
    /// tinted, filled backgrounds rounded — into a context in `content`'s
    /// space, at the ancestors' combined alpha (the plain/semibold crossfade).
    ///
    /// ⚠️ NOT `layer.render(in:)`, and not `drawHierarchy`. In a glass
    /// container UIKit draws a label as a WHITE MASK and colours it at
    /// composite time (adaptive vibrancy), so a render of the layer tree is
    /// white glyphs and a white badge — dumped and looked at. `drawHierarchy`
    /// from inside an effect view draws nothing at all, at 35 ms a frame.
    /// The views still know their colours; this draws from them.
    private static func draw(_ view: UIView, in content: UIView, into context: CGContext, alpha: CGFloat) {
        guard !view.isHidden, view.alpha > 0.01, !(view is UIVisualEffectView) else { return }
        let alpha = alpha * view.alpha
        let rect = content.convert(view.bounds, from: view)
        let traits = content.traitCollection
        if let fill = view.backgroundColor?.resolvedColor(with: traits), fill.cgColor.alpha > 0.01 {
            let radius = min(view.layer.cornerRadius, min(rect.width, rect.height) / 2)
            context.saveGState()
            context.setAlpha(alpha)
            context.setFillColor(fill.cgColor)
            context.addPath(UIBezierPath(roundedRect: rect, cornerRadius: radius).cgPath)
            context.fillPath()
            context.restoreGState()
        }
        if let label = view as? UILabel, let text = label.text, !text.isEmpty {
            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = label.textAlignment
            paragraph.lineBreakMode = label.lineBreakMode
            let attributes: [NSAttributedString.Key: Any] = [
                .font: label.font ?? UIFont.preferredFont(forTextStyle: .body),
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
                // ⚠️ `.label`, not the view's `tintColor`: a glass container
                // recolours its vibrant content to its backdrop, so a button's
                // symbol shows dark on this bar while its tint still reads
                // system blue — the copy came out blue, filmed. `.label` is the
                // nearest resolved colour to what shows.
                image = image.withTintColor(UIColor.label.resolvedColor(with: traits), renderingMode: .alwaysOriginal)
            }
            let size = image.size
            guard size.width > 0, size.height > 0, rect.width > 0, rect.height > 0 else { return }
            let ratio = min(rect.width / size.width, rect.height / size.height, 1)
            let fitted = CGRect(x: rect.midX - size.width * ratio / 2, y: rect.midY - size.height * ratio / 2,
                                width: size.width * ratio, height: size.height * ratio)
            UIGraphicsPushContext(context)
            // ⚠️ The alpha goes in the call: `UIImage.draw(in:)` ignores the
            // context's `setAlpha` — see the animated-map-icons notes.
            image.draw(in: fitted, blendMode: .normal, alpha: alpha)
            UIGraphicsPopContext()
        }
        for child in view.subviews {
            draw(child, in: content, into: context, alpha: alpha)
        }
    }

    private func hideCopy() {
        copy?.isHidden = true
        backdrop = nil
        if let maskedLayer, maskedLayer.mask === sourceMask { maskedLayer.mask = nil }
        maskedLayer = nil
    }

    private func trace(capture: Double, render: Double) {
        let now = CACurrentMediaTime()
        traceCost.frames += 1
        traceCost.capture += capture
        traceCost.render += render
        if traceCost.since == 0 { traceCost.since = now }
        if now - traceCost.since >= 1 {
            let n = Double(traceCost.frames)
            print(String(format: "[SelectorGlassLens] %d frames: capture %.2f ms, render %.2f ms (mean); held %d/%d, max stretch %.2f, max speed %.0f pt/s, snapshots %d",
                         traceCost.frames, traceCost.capture / n * 1000, traceCost.render / n * 1000,
                         traceMotion.held, traceMotion.frames, traceMotion.maxStretch, traceMotion.maxSpeed, traceSnapshots))
            traceSnapshots = 0
            traceCost = (0, 0, 0, now)
            traceMotion = (0, 0, 0, 0, traceMotion.wasHeld)
        }
    }

    #if DEBUG
    /// Runs the spring to rest, frame by frame, as the display link would — a
    /// test has no run loop to wait on.
    func runSpringToRest() {
        for _ in 0..<600 where isLifted {
            if advance(by: 1 / 120) { break }
        }
    }

    /// Whether the refracted copy is showing.
    var debugCopyIsShowing: Bool { copy?.isHidden == false }
    /// The magnification of the last rendered copy.
    private(set) var debugMagnification: CGFloat = 1
    /// Whether the strip's real titles are cut out under the lens.
    var debugSourceIsMasked: Bool { maskedLayer?.mask != nil && maskedLayer?.mask === sourceMask }
    /// Ends a settle at once, as the last frame of its display link would.
    func debugFinishSettle() {
        guard settleStarted != nil else { return }
        advanceSettle(at: CACurrentMediaTime() + Lift.settleDuration)
    }
    #endif
}

/// The refracted copy's surface: a `CAMetalLayer` the shader draws into. The
/// shader leaves everything outside the capsule transparent, so it needs no
/// clipping of its own.
private final class LensCopyView: UIView {
    override class var layerClass: AnyClass { CAMetalLayer.self }
    var metalLayer: CAMetalLayer { layer as! CAMetalLayer }

    init(device: MTLDevice?) {
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        isOpaque = false
        backgroundColor = .clear
        let layer = metalLayer
        layer.device = device
        layer.pixelFormat = .bgra8Unorm
        layer.isOpaque = false
        layer.framebufferOnly = true
        // Presented from the render, inside the transaction that moves the
        // lens — see `LensRefractor.render(source:into:uniforms:)`.
        layer.presentsWithTransaction = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
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
