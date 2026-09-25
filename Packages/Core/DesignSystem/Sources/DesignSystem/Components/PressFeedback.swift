import ObjectiveC
import QuartzCore
import UIKit
// `state` and the `touches…` overrides — see `PressGestureRecognizer`.
import UIKit.UIGestureRecognizerSubclass

/// A control answering the finger: it gives a little under a press, springs
/// back when let go, and ticks when the press turns out to be a tap — or, for a
/// surface a finger works by dragging (a ruler), grows a little for as long as
/// the finger is on it.
///
/// ```
///   finger down        finger up (a tap)          finger up (a scroll took it)
///   ┌──────┐  0.1s     ┌────────┐ spring           ┌──────┐ spring
///   │ ▣▣▣▣ │ ──────▶   │  ▣▣▣▣  │ ─────▶ ♪ tick     │ ▣▣▣▣ │ ─────▶ (silent)
///   └──────┘  gives    └────────┘ back, over       └──────┘ back
/// ```
///
/// ⚠️ **ONE MECHANISM, TWO HOOKS, AND THE HOOK IS DECIDED BY WHAT THE VIEW IS.**
/// A `UIControl` is driven by its OWN events (`attach(to:moving:…)`): the press
/// starts on `.touchDown`, ends on `.touchDragExit` / `.touchCancel` /
/// `.touchUpOutside`, and the sound plays on `.touchUpInside` — the very event
/// that fires the control's action, so the tick and the action cannot
/// disagree about what a tap was. A plain view has no such events, so it gets
/// `PressGestureRecognizer` (`attach(toView:…)`), which watches the touch and
/// never recognises. Hooking controls through a recogniser too would have been
/// one code path, and would have made the sound a second opinion on a question
/// the control already answers.
///
/// ⚠️ **THE PRESS NEVER WRITES THE VIEW'S `transform`.** It is two ADDITIVE
/// Core Animation layers on top of whatever the model says — a held factor and
/// a transient that eases into it — so it composes with every other motion the
/// view is in the middle of rather than replacing it. Three owners already
/// write these transforms: Upload's band pops each element in from
/// `BandPop.collapsedScale`, the finalisation strip ripples its tiles in, and
/// layout reads frames through `convert(_:to:)` (the effects row measures the
/// very pill that was just tapped, from inside its tap). A press written to the
/// model would race the first two and lie to the third; one that only exists in
/// the render tree can do neither. This is also why it needs no completion
/// handler: the transients remove themselves, and the held factor is removed
/// on release in the same transaction that adds the spring back.
///
/// ⚠️ **AND IT IS DRAWN — MEASURED OFF A SCREEN RECORDING, SINCE NOTHING IN
/// THE PROCESS CAN SAY SO.** A render-tree-only press is invisible to every
/// property a test can read, so it was filmed (iOS 27 simulator, a real
/// XCUITest finger): a 56pt look card held down went 168 → 154px wide within
/// 80ms (0.917, asked 0.921) and stayed there; the straightening dial's needle
/// went 60 → 63px the moment the finger landed, held through the drag, and on
/// the lift came back through 59px — the spring's overshoot, one pixel below
/// rest — to 60.
///
/// ⚠️ **THE SOUND PLAYS ON THE RELEASE THAT COUNTS AS A TAP, NEVER ON THE
/// TOUCH-DOWN.** Most of these controls live in horizontal scrollers, and every
/// scroll starts with a finger landing on something: a tick on touch-down would
/// click at the start of every scroll that happened to begin on a chip.
///
/// ⚠️ **REDUCE MOTION TAKES THE SCALE AWAY AND LEAVES THE SOUND.** A sound is
/// not motion, and it is the part that says the tap was taken.
@MainActor
public final class PressFeedback {
    /// What the feedback does under a finger.
    public enum Style: Equatable, Sendable {
        /// A button: gives a little under the press, springs back, ticks on a
        /// tap.
        case press
        /// A surface worked by dragging — a ruler: grows a little while held,
        /// settles back on release, silent (it already clicks through its own
        /// detent haptics).
        case hold
    }

    public enum Metrics {
        /// How far a press takes each end of an element's longer side, in
        /// points.
        ///
        /// ⚠️ **A DEPTH, NOT A RATIO, BECAUSE THE BAND'S ELEMENTS RUN FROM A 26pt
        /// SWATCH TO A 208pt THUMBNAIL.** One ratio is either invisible on the
        /// small ones or a lurch on the big ones: 0.94 is under two points on a
        /// swatch and twelve on a tile. The same few points off every edge reads
        /// as the same press on both. See `pressedScale(for:)`.
        public static let depth: CGFloat = 3
        /// The bounds `depth` is held within.
        ///
        /// ⚠️ **0.9 AT THE SMALL END**, where `depth` alone would take a 30pt
        /// glyph to 0.8 and the icon would visibly jump rather than give;
        /// **0.97 AT THE LARGE END**, so nothing bigger than the strip's 208pt
        /// tiles ever gives by less than they do — at 0.97 a tile loses six
        /// points of height, and past that `depth` alone would fade towards
        /// nothing.
        public static let pressedScales: ClosedRange<CGFloat> = 0.9...0.97
        /// What a held surface grows to.
        ///
        /// ⚠️ **SIX PERCENT: ENOUGH FOR A RULER'S TICKS TO VISIBLY LENGTHEN,
        /// LITTLE ENOUGH THAT ITS SPACING STILL READS AS THE SAME SCALE.** iOS's
        /// own sliders thicken while held for the same reason — the control says
        /// it has been picked up — and a ruler has no thumb to enlarge, so the
        /// strip itself is what grows.
        public static let heldScale: CGFloat = 1.06
        /// How quickly an element gives under the finger.
        ///
        /// ⚠️ **INSTANT IS UNDER A TENTH OF A SECOND, AND A TAP IS SHORTER THAN
        /// THAT.** Eight measured taps lifted 32-98ms after they landed
        /// (Upload's `ChipScrollView` has the table); a press that took longer
        /// would still be on its way down when the finger left, and the author
        /// would see only the spring back.
        public static let response: TimeInterval = 0.1
        /// The spring back's response — Upload's `BandPop.duration`, the time
        /// the band's elements take to land.
        ///
        /// ⚠️ **STATED HERE, NOT IMPORTED: UPLOAD DEPENDS ON DESIGNSYSTEM, NOT
        /// THE OTHER WAY ROUND.** `BandPopTests` holds the two equal.
        public static let releaseResponse: TimeInterval = 0.28
        /// How far past rest the spring back travels, as a fraction of the
        /// element's size — the overshoot a band element lands with.
        ///
        /// ⚠️ **BANDPOP'S OVERSHOOT, NOT BANDPOP'S DAMPING.** An underdamped
        /// spring overshoots by a fixed FRACTION OF ITS TRAVEL, and a press
        /// travels a fifth of what an arrival does (0.06 against 0.24): at the
        /// band's 0.7 damping the release would overshoot by 0.3% of the
        /// element — a third of a point on a pill, which is no bounce at all.
        /// What carries over is what the eye sees: an arrival from 0.76 at 0.7
        /// damping passes rest by `0.24 × e^(−π·0.7/√(1−0.7²))` = 1.1% of the
        /// element, and so does a release. `releaseDampingRatio(travel:)` solves
        /// the damping from that.
        public static let landingOvershoot: CGFloat = 0.011
        /// How much a pressed element fades, for the hosts that ask
        /// (`dims: true`) — the app-wide press, 25 September 2026: "a light
        /// shrink and a slight dim, the same on every button".
        ///
        /// ⚠️ **OPACITY, NOT A DARKER FILL**, and additive, like the scale: a
        /// material pill darkened stops reading as a material, and a fill
        /// written to the model would race whoever else animates the view's
        /// alpha (a card's furniture fades in). A fifth of a step off opacity
        /// reads as "held" without the control looking disabled.
        public static let pressedDim: Float = 0.15
    }

    /// The scale a press takes an element of `size` to — see `Metrics.depth`.
    public static func pressedScale(for size: CGSize) -> CGFloat {
        let longer = max(size.width, size.height)
        guard longer > 0 else { return Metrics.pressedScales.upperBound }
        let scale = 1 - 2 * Metrics.depth / longer
        return min(max(scale, Metrics.pressedScales.lowerBound), Metrics.pressedScales.upperBound)
    }

    /// The damping ratio that makes a spring travelling `travel` (a fraction of
    /// the element's size) overshoot by `Metrics.landingOvershoot`.
    ///
    /// For an underdamped spring the first overshoot is `travel × e^(−πζ/√(1−ζ²))`;
    /// solved for ζ with `L = −ln(overshoot / travel) / π`, ζ = L / √(1 + L²).
    /// A travel no larger than the overshoot cannot be asked to pass rest by that
    /// much, and gets a spring that does not pass it at all.
    public static func releaseDampingRatio(travel: CGFloat) -> CGFloat {
        let travel = abs(travel)
        guard travel > Metrics.landingOvershoot else { return 1 }
        let lead = -log(Metrics.landingOvershoot / travel) / .pi
        return lead / (1 + lead * lead).squareRoot()
    }

    /// The factor the target is currently held at: the pressed or grown scale
    /// while a finger is down, 1 otherwise — and 1 throughout under Reduce
    /// Motion, when nothing moves.
    ///
    /// ⚠️ **THE TARGET, NOT THE PRESENTATION.** A ruler divides its drag by
    /// this, so the tick under the finger stays under it while the strip is
    /// grown (`StraightenDialView`). Reading `layer.presentation()` would be
    /// exact during the first tenth of a second too, at the price of a layer
    /// copy on every sample of every drag; a drag rarely starts inside that
    /// tenth, and when it does the error is a fraction of the six percent.
    public private(set) var scale: CGFloat = 1

    /// Whether a finger is pressing, as far as this feedback knows.
    public private(set) var isPressed = false

    public let style: Style

    /// What moves — the control itself, or a view it stands for.
    private weak var target: UIView?
    private let sound: UISound?
    /// False for a control that already moves under a finger of its own accord.
    private let scales: Bool
    /// Whether a press also fades the target a little — see `Metrics.pressedDim`.
    private let dims: Bool
    private var isDimmed = false
    private let reducesMotion: @MainActor () -> Bool

    private init(
        target: UIView, style: Style, sound: UISound?, scales: Bool, dims: Bool = false,
        reducesMotion: @escaping @MainActor () -> Bool
    ) {
        self.target = target
        self.style = style
        self.sound = sound
        self.scales = scales
        self.dims = dims
        self.reducesMotion = reducesMotion
    }

    // MARK: - Attaching

    /// Wires `control` through its own events.
    ///
    /// - Parameters:
    ///   - moving: the view that gives under the press — `control` itself unless
    ///     the control is a transparent layer over what the author sees (a
    ///     filter card is a picture and a caption under a clear button).
    ///   - scales: false for a control that already answers the finger with a
    ///     motion of its own — an interactive `UIGlassEffect` scales and shimmers
    ///     under a touch, and a second scale inside it would fight the first.
    ///     Such a control still ticks.
    ///
    /// ⚠️ **ONE ACTION PER GROUP OF EVENTS, ADDED ONCE, HERE.** Nothing is
    /// allocated per touch except the animations themselves.
    @discardableResult
    public static func attach(
        to control: UIControl,
        moving target: UIView? = nil,
        sound: UISound? = .tap,
        scales: Bool = true,
        dims: Bool = false,
        reducesMotion: @escaping @MainActor () -> Bool = { UIAccessibility.isReduceMotionEnabled }
    ) -> PressFeedback {
        let feedback = PressFeedback(
            target: target ?? control, style: .press, sound: sound, scales: scales, dims: dims,
            reducesMotion: reducesMotion
        )
        control.addAction(UIAction { _ in feedback.press() }, for: [.touchDown, .touchDragEnter])
        control.addAction(
            UIAction { _ in feedback.release(asTap: false) },
            for: [.touchDragExit, .touchUpOutside, .touchCancel]
        )
        control.addAction(UIAction { _ in feedback.release(asTap: true) }, for: .touchUpInside)
        remember(feedback, on: control)
        return feedback
    }

    /// Wires a view that is not a control — a thumbnail, a ruler — through a
    /// recogniser that watches its touches without ever taking one.
    ///
    /// ⚠️ **IT TURNS `isUserInteractionEnabled` ON**, because a view that
    /// ignores touches is never the view a touch lands on: a `UIImageView` is
    /// born ignoring them, and a photograph's tile would never feel a finger.
    /// That changes nothing for anything else: the recogniser never recognises,
    /// and the scroller above still gets the touch.
    @discardableResult
    public static func attach(
        toView view: UIView,
        style: Style = .press,
        moving target: UIView? = nil,
        sound: UISound? = .tap,
        dims: Bool = false,
        reducesMotion: @escaping @MainActor () -> Bool = { UIAccessibility.isReduceMotionEnabled }
    ) -> PressFeedback {
        let feedback = PressFeedback(
            target: target ?? view, style: style, sound: sound, scales: true,
            dims: dims && style == .press, reducesMotion: reducesMotion
        )
        view.isUserInteractionEnabled = true
        view.addGestureRecognizer(PressGestureRecognizer(feedback: feedback))
        remember(feedback, on: view)
        return feedback
    }

    /// A press for a view whose HOST already knows when the finger is down —
    /// a scrubber whose own gesture owns the touch — and calls `press()` and
    /// `release(asTap:)` itself. No hook is installed.
    ///
    /// ⚠️ **NOT A SECOND RECOGNISER ON A VIEW THAT HAS ITS OWN.** The page
    /// indicator's scrub is a zero-delay recogniser; a watcher beside it would
    /// be one more party to every arbitration that touch goes through.
    public static func driven(
        by view: UIView,
        sound: UISound? = nil,
        dims: Bool = false,
        reducesMotion: @escaping @MainActor () -> Bool = { UIAccessibility.isReduceMotionEnabled }
    ) -> PressFeedback {
        let feedback = PressFeedback(
            target: view, style: .press, sound: sound, scales: true, dims: dims,
            reducesMotion: reducesMotion
        )
        remember(feedback, on: view)
        return feedback
    }

    /// The feedback attached to `view`, if any — for a host's tests, which
    /// cannot put a finger down, to drive the same routines a finger does.
    public static func attached(to view: UIView) -> PressFeedback? {
        objc_getAssociatedObject(view, &Association.key) as? PressFeedback
    }

    private enum Association {
        /// ⚠️ **ITS ADDRESS IS THE KEY, NOT ITS VALUE** — which is why it is a
        /// `var`: only stored storage has an address to hand to the runtime.
        nonisolated(unsafe) static var key: UInt8 = 0
    }

    private static func remember(_ feedback: PressFeedback, on view: UIView) {
        objc_setAssociatedObject(view, &Association.key, feedback, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }

    // MARK: - The press

    /// The finger came down — or came back over a control it strayed from.
    public func press() {
        guard !isPressed, let target else { return }
        isPressed = true
        // The dim is not motion: it stays under Reduce Motion, like the sound.
        if dims {
            isDimmed = true
            target.layer.add(Self.dimHolding(), forKey: Self.dimKey)
            target.layer.add(Self.dimEasing(), forKey: nil)
        }
        let moves = scales && !reducesMotion()
        let factor = style == .hold ? Metrics.heldScale : Self.pressedScale(for: target.bounds.size)
        scale = moves ? factor : 1
        #if DEBUG
        record(.pressed(scale: scale))
        #endif
        guard moves else { return }
        let layer = target.layer
        // ⚠️ **HELD, THEN EASED INTO — IN THAT ORDER, IN ONE TURN.** The hold
        // puts the element at `factor` at once and the transient starts at
        // `1 / factor`, so on the first frame the two cancel and nothing jumps.
        layer.add(Self.holding(factor), forKey: Self.holdKey)
        layer.add(Self.easing(from: 1 / factor), forKey: nil)
    }

    /// The finger lifted, strayed, or was taken by something else.
    ///
    /// ⚠️ **THE SPRING STARTS FROM THE HELD FACTOR, NOT FROM WHERE THE ELEMENT
    /// IS DRAWN, AND THAT IS CORRECT.** On a tap quicker than `response` the
    /// ease into the press is still running; it is left to finish, and the
    /// spring back is added on top of it. Both are additive, so the element is
    /// drawn at their product — continuous at the moment of release, and home
    /// at rest when both are done. It is the scheme UIKit's own additive
    /// animations use, written in multiplication.
    public func release(asTap: Bool) {
        let wasPressed = isPressed
        let held = scale
        isPressed = false
        scale = 1
        if isDimmed, let layer = target?.layer {
            isDimmed = false
            layer.removeAnimation(forKey: Self.dimKey)
            layer.add(Self.dimLifting(), forKey: nil)
        }
        guard wasPressed || asTap else { return }
        let sprang = wasPressed && held != 1
        if sprang, let layer = target?.layer {
            layer.removeAnimation(forKey: Self.holdKey)
            layer.add(Self.springing(from: held), forKey: nil)
        }
        // ⚠️ **ONE DECISION GATES THE SOUND AND IS WHAT IS RECORDED** — so a
        // test reading "ticked" reads the very condition the tick plays on.
        let ticks = asTap && sound != nil
        if ticks { sound?.play() }
        #if DEBUG
        record(.released(tap: ticks, sprang: sprang))
        #endif
    }

    // MARK: - The curves

    private static let holdKey = "designSystem.pressFeedback.hold"
    private static let dimKey = "designSystem.pressFeedback.dim"

    /// The dim, on the scale's scheme: HELD at `-pressedDim` (additive opacity
    /// is summed onto the model's), with a transient that starts at the
    /// opposite so the first frame nets to nothing and eases into the hold.
    private static func dimHolding() -> CABasicAnimation {
        let hold = CABasicAnimation(keyPath: "opacity")
        hold.isAdditive = true
        hold.fromValue = -Metrics.pressedDim
        hold.toValue = -Metrics.pressedDim
        hold.duration = 1
        hold.fillMode = .forwards
        hold.isRemovedOnCompletion = false
        return hold
    }

    private static func dimEasing() -> CABasicAnimation {
        let ease = CABasicAnimation(keyPath: "opacity")
        ease.isAdditive = true
        ease.fromValue = Metrics.pressedDim
        ease.toValue = 0
        ease.duration = Metrics.response
        ease.timingFunction = CAMediaTimingFunction(name: .easeOut)
        return ease
    }

    /// Back up from the held dim over the spring's own response.
    private static func dimLifting() -> CABasicAnimation {
        let lift = CABasicAnimation(keyPath: "opacity")
        lift.isAdditive = true
        lift.fromValue = -Metrics.pressedDim
        lift.toValue = 0
        lift.duration = Metrics.releaseResponse
        lift.timingFunction = CAMediaTimingFunction(name: .easeOut)
        return lift
    }

    /// ⚠️ **ADDITIVE ON `transform` MEANS CONCATENATED**, which is what makes a
    /// press compose with an arrival rather than add half-sizes together:
    /// Core Animation's own words for `isAdditive` are "for affine transforms
    /// the two matrices are concatenated".
    private static func holding(_ factor: CGFloat) -> CABasicAnimation {
        let hold = CABasicAnimation(keyPath: "transform")
        hold.isAdditive = true
        let value = NSValue(caTransform3D: CATransform3DMakeScale(factor, factor, 1))
        hold.fromValue = value
        hold.toValue = value
        hold.duration = 1
        hold.fillMode = .forwards
        hold.isRemovedOnCompletion = false
        return hold
    }

    private static func easing(from factor: CGFloat) -> CABasicAnimation {
        let ease = CABasicAnimation(keyPath: "transform")
        ease.isAdditive = true
        ease.fromValue = NSValue(caTransform3D: CATransform3DMakeScale(factor, factor, 1))
        ease.toValue = NSValue(caTransform3D: CATransform3DIdentity)
        ease.duration = Metrics.response
        ease.timingFunction = CAMediaTimingFunction(name: .easeOut)
        return ease
    }

    /// ⚠️ **MASS, STIFFNESS AND DAMPING STATED, NOT `perceptualDuration:bounce:`.**
    /// The damping is a ratio solved from the travel, and the ratio is what the
    /// three physical terms say exactly: ω = 2π / response, stiffness = ω²,
    /// damping = 2ζω at unit mass.
    private static func springing(from factor: CGFloat) -> CASpringAnimation {
        let spring = CASpringAnimation(keyPath: "transform")
        spring.isAdditive = true
        spring.fromValue = NSValue(caTransform3D: CATransform3DMakeScale(factor, factor, 1))
        spring.toValue = NSValue(caTransform3D: CATransform3DIdentity)
        let omega = 2 * CGFloat.pi / CGFloat(Metrics.releaseResponse)
        spring.mass = 1
        spring.stiffness = omega * omega
        spring.damping = 2 * releaseDampingRatio(travel: 1 - factor) * omega
        spring.duration = spring.settlingDuration
        return spring
    }

    // MARK: - Tests

    #if DEBUG
    /// A decision the feedback made.
    public enum Event: Equatable, Sendable {
        /// Pressed, to `scale` — 1 when nothing moved (Reduce Motion, or a
        /// control that moves itself).
        case pressed(scale: CGFloat)
        /// Let go; `tap` is whether it TICKED — a tap on something with a
        /// sound — and `sprang` whether anything was sprung back.
        case released(tap: Bool, sprang: Bool)
    }

    /// Internal for tests: the last decisions, oldest first.
    ///
    /// ⚠️ **THE DECISION, BECAUSE THE DRAWING CANNOT BE ASKED.** The press lives
    /// in the render tree only, so `transform` reads whatever the model says
    /// throughout, and a presentation layer is not computed in a test host that
    /// never renders.
    /// ⚠️ **AND CAPPED**, because this runs on every tap of a debug build for as
    /// long as the app is open.
    public private(set) var debugEvents: [Event] = []

    private func record(_ event: Event) {
        if debugEvents.count >= 16 { debugEvents.removeFirst() }
        debugEvents.append(event)
    }

    /// Internal for tests: whether the held factor is on the layer — the one
    /// piece of the drawing that CAN be asked, because it is attached by key.
    public var debugIsHeldOnTheLayer: Bool {
        target?.layer.animation(forKey: Self.holdKey) != nil
    }

    /// Internal for tests: whether the held dim is on the layer.
    public var debugIsDimmedOnTheLayer: Bool {
        target?.layer.animation(forKey: Self.dimKey) != nil
    }

    /// Internal for tests: the recogniser a plain view was given, nil for a
    /// control.
    public var debugRecognizer: UIGestureRecognizer? { recognizer }

    /// Internal for tests: the view that gives under the press.
    public var debugTarget: UIView? { target }
    #endif

    /// Set by the recogniser that drives this feedback, when one does.
    fileprivate weak var recognizer: PressGestureRecognizer?
}

/// Watches a touch on a view that is not a control, and tells a
/// `PressFeedback` about it. It never recognises.
///
/// ⚠️ **NEVER RECOGNISING IS WHAT MAKES IT SAFE TO PUT ON ANYTHING.** A
/// recogniser that reaches `.recognized` PREVENTS every recogniser it does not
/// recognise simultaneously with — ancestors included — whether or not it has
/// an action, which this codebase has paid for twice (a no-action tap that
/// silenced a cell's play/pause; a recognised long press that froze the
/// timeline's scroll). This one stays `.possible` until it fails itself, so it
/// can prevent nothing, and every scroller and tap above and beside it behaves
/// exactly as it did.
///
/// ⚠️ **IT GIVES WAY TO ANY DRAG THAT IS NOT ITS OWN VIEW'S.** When a scroller's
/// pan, a sheet's, or the stack's back-swipe takes the touch, that recogniser
/// fails this one (`canBePrevented(by:)`), `reset()` runs, and the press is
/// released without a sound: the finger is scrolling now, not pressing. A drag
/// belonging to the view itself — a ruler's own pan — is the interaction the
/// feedback is FOR, and does not end it. A tap recognising beside it does not
/// end it either: that tap is the press completing, and it must still tick.
///
/// ⚠️ **MEASURED WITH REAL TOUCHES, BECAUSE NO UNIT TEST CAN ARBITRATE.**
/// XCUITest fingers on the iOS 27 simulator: a drag that began on a
/// photograph's tile in the finalisation strip was released without a tick
/// 123ms later, as the strip's scroller took it; a tap on a clip's tile — which
/// the tile's own tap recogniser also answers — ticked; the straightening dial
/// grew as the finger landed, stayed grown through a 120pt drag its own pan
/// was carrying, and let go on the lift.
@MainActor
final class PressGestureRecognizer: UIGestureRecognizer {
    private let feedback: PressFeedback
    /// Whether a finger is pressing, and which one — the first to land. A
    /// second finger is not a second press.
    private var isPressing = false
    private weak var touch: UITouch?

    init(feedback: PressFeedback) {
        self.feedback = feedback
        super.init(target: nil, action: nil)
        feedback.recognizer = self
        cancelsTouchesInView = false
        delaysTouchesBegan = false
        // ⚠️ DEFAULT TRUE, AND IT WOULD HOLD THE VIEW'S OWN `touchesEnded`
        // BACK until this failed. It fails in the same call, but "the same
        // call" is an ordering fact nobody should have to rely on.
        delaysTouchesEnded = false
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        guard !isPressing, let first = touches.first else { return }
        touch = first
        began()
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        guard isPressing, let touch, touches.contains(touch), let view else { return }
        moved(inside: view.bounds.contains(touch.location(in: view)))
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        guard isPressing, let touch, touches.contains(touch) else { return }
        ended()
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        guard isPressing, let touch, touches.contains(touch) else { return }
        cancelled()
    }

    /// ⚠️ **THE PATH A PREVENTION TAKES.** Failed by a drag that took the touch,
    /// this is the only call the recogniser gets — no `touchesCancelled` — so a
    /// press still held here is one a scroll took away.
    override func reset() {
        super.reset()
        let wasPressing = isPressing
        isPressing = false
        touch = nil
        if wasPressing { feedback.release(asTap: false) }
    }

    override func canPrevent(_ preventedGestureRecognizer: UIGestureRecognizer) -> Bool { false }

    override func canBePrevented(by preventingGestureRecognizer: UIGestureRecognizer) -> Bool {
        preventingGestureRecognizer is UIPanGestureRecognizer && preventingGestureRecognizer.view !== view
    }

    // MARK: - The routines a touch drives

    func began() {
        isPressing = true
        feedback.press()
    }

    /// ⚠️ **A BUTTON'S PRESS ENDS WHEN THE FINGER LEAVES IT; A SURFACE'S DOES
    /// NOT.** A ruler is dragged well past its own bounds — that is using it,
    /// not leaving it.
    func moved(inside: Bool) {
        guard feedback.style == .press, !inside else { return }
        isPressing = false
        feedback.release(asTap: false)
        state = .failed
    }

    /// The finger lifted while still pressing: a tap, for a button.
    ///
    /// ⚠️ **A SURFACE'S LIFT IS NOT A TAP, AND THIS IS THE ONE LINE THAT SAYS
    /// SO.** A ruler is let go of after a drag; ticking on that would add a
    /// click to the detent haptics it already gives.
    func ended() {
        isPressing = false
        feedback.release(asTap: feedback.style == .press)
        state = .failed
    }

    func cancelled() {
        isPressing = false
        feedback.release(asTap: false)
        state = .failed
    }

    #if DEBUG
    /// Internal for tests: a touch landing, straying, lifting, or being taken by
    /// a drag — the same routines the overrides above call, since a test cannot
    /// make a real `UITouch`.
    func debugTouchDown() { began() }
    func debugTouchMoved(inside: Bool) { moved(inside: inside) }
    func debugTouchUp() { ended() }
    func debugTouchCancelled() { cancelled() }
    func debugTakenByADrag() { reset() }
    #endif
}
