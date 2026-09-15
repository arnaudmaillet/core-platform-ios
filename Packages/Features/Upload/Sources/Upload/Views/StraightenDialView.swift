import DesignSystem
import UIKit

/// Where a straightening drag lands, as arithmetic.
///
/// ⚠️ **PURE, FOR THE REASON `CarouselBackSwipe` IS AND `PageScrubber` IS.** A
/// `UIPanGestureRecognizer`'s translation cannot be set, so a rule that lives
/// inside the gesture can only be checked by a finger. Separated, every clause
/// below is a test with numbers in it.
enum StraightenDial {
    /// How far the dial turns either way. Photos offers the same 45°, and it is
    /// the honest limit for a *straightening* tool: past it the viewer is not
    /// levelling a horizon, they are turning the picture on its side, which is
    /// what the quarter-turn button is for.
    static let span: CGFloat = 45

    /// ⚠️ **THE WHOLE FEEL OF THE CONTROL IS THIS NUMBER.** At 6pt per degree a
    /// comfortable 120pt drag covers twenty degrees, and one degree — the unit a
    /// horizon is actually levelled in — is a deliberate 6pt of travel rather
    /// than a pixel nobody can aim at. `IconSelectorBar` records the cost of
    /// getting the scale of a strip's gesture wrong by an order of magnitude.
    static let pointsPerDegree: CGFloat = 6

    /// A taller tick, and a click, every five degrees.
    static let detent: CGFloat = 5

    static func clamped(_ angle: CGFloat) -> CGFloat { min(max(angle, -span), span) }

    /// The angle after a finger has travelled `travel` points since the last
    /// sample.
    ///
    /// ⚠️ **INCREMENTAL, NOT MEASURED FROM THE TOUCH-DOWN — AND THAT IS WHAT
    /// RE-ANCHORS IT AT THE ENDS.** Computing `origin - totalTravel / scale`
    /// reads correctly and goes numb: push 200pt past +45°, then pull back, and
    /// nothing moves until the finger has retraced all 200. `PageScrubber` names
    /// the same defect from the other side — *"putting a finger on the middle of
    /// the chip teleported a twelve-page post to page six before the drag had
    /// moved at all"*. Advancing from wherever the value actually is has neither
    /// failure.
    ///
    /// ⚠️ AND THE SIGN IS THE PHYSICAL ONE. The ruler is a strip lying under a
    /// fixed needle: the tick you put your finger on follows your finger. Dragging
    /// right carries smaller numbers under the needle, so the picture turns back
    /// anticlockwise — which is why `travel` is SUBTRACTED.
    static func advanced(_ angle: CGFloat, by travel: CGFloat) -> CGFloat {
        clamped(angle - travel / pointsPerDegree)
    }

    /// Which detent the needle is nearest — the only thing a click may be fired
    /// from, and only when it changes.
    static func detentIndex(for angle: CGFloat) -> Int { Int((angle / detent).rounded()) }

    /// ⚠️ **SNAPPED TO A TRUE ZERO, BECAUSE `MediaCrop.isUntouched` IS AN EXACT
    /// `==`.** A dial left at 0.2° is a picture the author considers unturned and
    /// the renderer considers turned: a full GPU round trip, a resample, and a
    /// bounding box wider than the source — all for a fifth of a degree nobody
    /// can see. Under half a degree the answer is zero, and it is exactly zero.
    static func settled(_ angle: CGFloat) -> CGFloat { abs(angle) < 0.5 ? 0 : angle }

    /// What the readout spells. Whole degrees: a tenth of a degree is noise the
    /// viewer cannot act on.
    static func reading(_ angle: CGFloat) -> String { "\(Int(angle.rounded()))°" }
}

/// The straightening ruler that sits in the editing band: a strip of degree
/// ticks running under a fixed needle, with the current angle spelled above it.
///
/// ```
///                    0°
///   · · · ┃ · · · · ┃ · · · ▼ · · ┃ · · · ·
///        -10        -5           5
/// ```
///
/// ⚠️ **NOT A `UISlider`, AND NOT A SCROLL VIEW.** A slider shows a thumb
/// travelling a fixed track, which reads as "how far along" rather than "how many
/// degrees", and it cannot spell the unit. A scroll view would bring its own
/// recogniser into a band that has already had a drag stolen from it once — see
/// `UploadNavigationController.beginsInsideTheEditingBand`. A pan on a plain view
/// is the whole mechanism, and `StraightenDial` above is the whole rule.
///
/// ⚠️ **NO BACKGROUND AND NO MATERIAL**, because the band has none: *"the canvas
/// runs full-bleed underneath and the media is the subject; a plate here would cut
/// the picture in two"*. The lift off the picture comes from the editor's own
/// dissolve.
@MainActor
final class StraightenDialView: UIView {
    private enum Metrics {
        static let readout: CGFloat = 18
        static let ruler: CGFloat = 34
        static var height: CGFloat { readout + Spacing.xs + ruler }
        static let tick: CGFloat = 1
        static let shortTick: CGFloat = 8
        static let longTick: CGFloat = 14
        static let needle: CGFloat = 18
        /// Below this a tick is too faint to be worth drawing; it also fades the
        /// ruler out towards both ends so the strip reads as continuing rather
        /// than stopping.
        static let fade: CGFloat = 56
    }

    /// ⚠️ `nonisolated`, SO THE BAND'S TENANT CAN ADD IT UP. `MediaCropToolsView`
    /// states its own height as "the dial plus a gap plus a row of chips" inside a
    /// plain `Metrics` enum, which is not main-actor isolated; a static on an
    /// isolated class is, and the sum would not compile.
    nonisolated static var height: CGFloat { Metrics.height }

    /// Announced as the finger moves, so the picture turns under it.
    var onTurn: ((CGFloat) -> Void)?

    /// Announced once the finger lifts, so the host can store a settled value
    /// rather than sixty of them.
    var onSettle: ((CGFloat) -> Void)?

    private(set) var angle: CGFloat = 0

    private let readout = UILabel()
    private let ruler = RulerStrip()

    /// ⚠️ STORED, NOT MADE PER CLICK — the inbox's settle haptic is the precedent
    /// (`private let selectionFeedback = UISelectionFeedbackGenerator()`), and a
    /// generator made inside the handler arrives cold and clicks late.
    private let click = UISelectionFeedbackGenerator()
    private var lastDetent = 0

    init() {
        super.init(frame: .zero)
        backgroundColor = .clear

        readout.font = .systemFont(ofSize: 13, weight: .semibold)
        readout.textAlignment = .center
        // ⚠️ **`.label`, AND IT WAS LITERAL WHITE FOR ONE GOOD REASON THAT HAS
        // SINCE GONE.** While the editor's ground was always black, `.label`
        // resolved to black in light appearance and this dial drew black ticks on
        // a black ground — measured from a screenshot. The ground now follows the
        // device, so the semantic ink is the one that can never be wrong: it turns
        // with the surface it is drawn on instead of guessing which one that is.
        readout.textColor = .label
        readout.text = StraightenDial.reading(0)
        readout.isAccessibilityElement = false

        ruler.backgroundColor = .clear
        ruler.isUserInteractionEnabled = false

        readout.constrain(in: self) { view in
            readout.topAnchor.constraint(equalTo: view.topAnchor)
            readout.leadingAnchor.constraint(equalTo: view.leadingAnchor)
            readout.trailingAnchor.constraint(equalTo: view.trailingAnchor)
            readout.heightAnchor.constraint(equalToConstant: Metrics.readout)
        }
        ruler.constrain(in: self) { view in
            ruler.topAnchor.constraint(equalTo: readout.bottomAnchor, constant: Spacing.xs)
            ruler.leadingAnchor.constraint(equalTo: view.leadingAnchor)
            ruler.trailingAnchor.constraint(equalTo: view.trailingAnchor)
            ruler.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        }
        heightAnchor.constraint(equalToConstant: Metrics.height).isActive = true

        let drag = UIPanGestureRecognizer(target: self, action: #selector(dragged))
        addGestureRecognizer(drag)

        // A tap on the readout is the way back to level — the same gesture Photos
        // gives the word RESET, without spending a second control on it.
        let tap = UITapGestureRecognizer(target: self, action: #selector(tapped))
        readout.isUserInteractionEnabled = true
        readout.addGestureRecognizer(tap)

        isAccessibilityElement = true
        accessibilityTraits = .adjustable
        accessibilityLabel = "Straighten"
        updateAccessibilityValue()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// States the angle without announcing it — for adopting the value a picture
    /// already carries when the viewer swipes to it.
    func setAngle(_ newAngle: CGFloat) {
        angle = StraightenDial.clamped(newAngle)
        lastDetent = StraightenDial.detentIndex(for: angle)
        redraw()
    }

    // MARK: - The drag

    @objc private func dragged(_ pan: UIPanGestureRecognizer) {
        switch pan.state {
        case .began:
            click.prepare()
            lastDetent = StraightenDial.detentIndex(for: angle)
        case .changed:
            let travel = pan.translation(in: self).x
            // ⚠️ ZEROED EVERY SAMPLE, because `advanced` takes the travel SINCE
            // THE LAST ONE. Leaving it cumulative would apply the whole drag on
            // every frame and the dial would run away.
            pan.setTranslation(.zero, in: self)
            turn(by: travel)
        case .ended, .cancelled, .failed:
            settle()
        default:
            break
        }
    }

    @objc private func tapped() {
        guard angle != 0 else { return }
        turnTo(0)
        settle()
    }

    private func turn(by travel: CGFloat) {
        turnTo(StraightenDial.advanced(angle, by: travel))
    }

    private func turnTo(_ newAngle: CGFloat) {
        guard newAngle != angle else { return }
        angle = newAngle
        let detent = StraightenDial.detentIndex(for: angle)
        if detent != lastDetent {
            lastDetent = detent
            click.selectionChanged()
        }
        redraw()
        onTurn?(angle)
    }

    private func settle() {
        let level = StraightenDial.settled(angle)
        if level != angle {
            angle = level
            redraw()
            onTurn?(angle)
        }
        onSettle?(angle)
    }

    private func redraw() {
        readout.text = StraightenDial.reading(angle)
        ruler.angle = angle
        updateAccessibilityValue()
    }

    private func updateAccessibilityValue() {
        accessibilityValue = StraightenDial.reading(angle)
    }

    override func accessibilityIncrement() {
        turnTo(StraightenDial.clamped(angle + 1))
        settle()
    }

    override func accessibilityDecrement() {
        turnTo(StraightenDial.clamped(angle - 1))
        settle()
    }

    /// The ticks themselves, drawn rather than assembled: a hundred and eighty
    /// one-point views would be a hundred and eighty layers to composite on every
    /// frame of a drag.
    private final class RulerStrip: UIView {
        var angle: CGFloat = 0 { didSet { setNeedsDisplay() } }

        init() {
            super.init(frame: .zero)
            backgroundColor = .clear
            // ⚠️ **REGISTERED ONCE, HERE — NOT IN `didMoveToWindow`.** That hook
            // runs on every entry to crop mode AND on every exit, so registering
            // there stacks a fresh observer per visit and the strip ends up
            // redrawing itself once for each mode it has already left. The rule
            // that puts work in `didMoveToWindow` is about MATERIALS contacting
            // the render server; nothing here does.
            registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (strip: RulerStrip, _) in
                strip.setNeedsDisplay()
            }
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

        override func draw(_ rect: CGRect) {
            guard let context = UIGraphicsGetCurrentContext(), bounds.width > 0 else { return }
            let middle = bounds.midX
            context.setLineWidth(Metrics.tick)
            context.setLineCap(.round)

            var degree = -StraightenDial.span
            while degree <= StraightenDial.span {
                let x = middle + (degree - angle) * StraightenDial.pointsPerDegree
                guard x >= -1, x <= bounds.width + 1 else {
                    degree += 1
                    continue
                }
                let isDetent = degree.truncatingRemainder(dividingBy: StraightenDial.detent) == 0
                let length = isDetent ? Metrics.longTick : Metrics.shortTick
                // Fading towards both ends says the strip continues past the
                // window rather than stopping at it.
                let distance = min(x, bounds.width - x)
                let strength = min(1, max(0, distance / Metrics.fade))
                let alpha = (isDetent ? 0.85 : 0.45) * strength
                context.setStrokeColor(UIColor.label.withAlphaComponent(alpha).cgColor)
                context.move(to: CGPoint(x: x, y: bounds.midY - length / 2))
                context.addLine(to: CGPoint(x: x, y: bounds.midY + length / 2))
                context.strokePath()
                degree += 1
            }

            // The needle, which never moves: it is the picture that turns.
            context.setLineWidth(2)
            context.setStrokeColor(UIColor.tintColor.cgColor)
            context.move(to: CGPoint(x: middle, y: bounds.midY - Metrics.needle / 2))
            context.addLine(to: CGPoint(x: middle, y: bounds.midY + Metrics.needle / 2))
            context.strokePath()
        }

    }
}

extension StraightenDialView {
    /// Internal for tests: the path a real drag takes, without a finger.
    func debugDrag(by travel: CGFloat) { turn(by: travel) }
    /// Internal for tests: the lift at the end of that drag.
    func debugEndDrag() { settle() }
    /// Internal for tests: the readout's own words.
    var debugReading: String? { readout.text }
    /// Internal for tests: the ink it is written in, so a literal colour left
    /// behind can be caught against the ground it stands on.
    var debugInk: UIColor? { readout.textColor }
    /// Internal for tests: the path a tap on the readout takes.
    func debugTapReadout() { tapped() }
}
