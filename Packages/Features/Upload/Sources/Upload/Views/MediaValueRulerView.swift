import DesignSystem
import UIKit

/// Where a drag along a value ruler lands, as arithmetic.
///
/// ⚠️ **PURE, FOR THE REASON `StraightenDial` IS.** A pan's translation cannot
/// be set, so a rule living inside the gesture could only be checked by a
/// finger.
///
/// Values are fractions — a dial runs -1...1 or 0...1 — and the ruler spells
/// them as whole percentages.
enum ValueRuler {
    /// ⚠️ **THE WHOLE FEEL OF THE CONTROL.** At 3pt per percent a full side is
    /// 300pt of travel — about one screen width — and one percent is a
    /// deliberate 3pt rather than a pixel nobody can aim at.
    static let pointsPerPercent: CGFloat = 3

    /// A tick every this many percent: 6pt apart, the straightening dial's
    /// density.
    static let tickEvery = 2

    /// A taller tick, and a click, every this many percent.
    static let detentEvery = 10

    static func clamped(_ value: Double, to range: ClosedRange<Double>) -> Double {
        value.isNaN ? range.lowerBound : min(max(value, range.lowerBound), range.upperBound)
    }

    /// The value after a finger has travelled `travel` points since the last
    /// sample.
    ///
    /// ⚠️ **INCREMENTAL, AND THE SIGN IS THE PHYSICAL ONE** — `StraightenDial`
    /// states both: the tick under the finger follows the finger, so dragging
    /// right brings smaller values under the needle, and advancing from where
    /// the value is (not from the touch-down) keeps the ends from going numb.
    static func advanced(_ value: Double, by travel: CGFloat, in range: ClosedRange<Double>) -> Double {
        clamped(value - Double(travel / pointsPerPercent) / 100, to: range)
    }

    /// Which detent the needle is nearest — a click fires only when it changes.
    static func detentIndex(for value: Double) -> Int {
        Int((value * 100 / Double(detentEvery)).rounded())
    }

    /// ⚠️ **WHOLE PERCENTAGES ONCE THE FINGER LIFTS.** The readout only ever
    /// spells whole numbers; storing 0.2349 behind "+23%" would be a value the
    /// author cannot see, and a dial left at 0.3% would be an edit that
    /// `LookAdjustments.isNeutral` counts and nobody can see either.
    static func settled(_ value: Double) -> Double {
        (value * 100).rounded() / 100
    }

    /// What the readout and a card spell, and what VoiceOver says: a whole
    /// percentage, signed on a two-sided dial.
    static func reading(_ value: Double, twoSided: Bool) -> (written: String, spoken: String) {
        let whole = Int((value * 100).rounded())
        guard twoSided, whole != 0 else { return ("\(whole)%", "\(whole) percent") }
        return whole > 0
            ? ("+\(whole)%", "plus \(whole) percent")
            : ("−\(-whole)%", "minus \(-whole) percent")
    }
}

/// The ruler a dial is turned on: a strip of percentage ticks running under a
/// fixed needle, the value spelled above it.
///
/// ```
///                   +20%
///   · · ┃ · · · · ┃ · · · ▼ · · ┃ · · · ·
/// ```
///
/// ⚠️ **THE STRAIGHTENING DIAL'S SHAPE AND METRICS, ON PURPOSE.** Effects and
/// Crop lay their band out the same way — a ruler over a row of chips — so the
/// two stay interchangeable to the eye. `StraightenDialView` records why this is
/// a pan on a plain view and not a slider or a scroll view.
///
/// ⚠️ **THE TICKS BETWEEN REST AND THE NEEDLE ARE TINTED.** A two-sided dial
/// rests in the middle, and -40 is as much an edit as +40; the tint grows out
/// of the rest both ways, which is what the slider's `neutralValue` fill did.
///
/// ⚠️ **A TAP ON THE READOUT PUTS THE DIAL BACK TO REST** — exactly, which a
/// drag can only do by landing on it.
@MainActor
final class MediaValueRulerView: UIView {
    private enum Metrics {
        static let readout: CGFloat = 18
        static let ruler: CGFloat = 34
        static var height: CGFloat { readout + Spacing.xs + ruler }
        static let tick: CGFloat = 1
        static let shortTick: CGFloat = 8
        static let longTick: CGFloat = 14
        static let needle: CGFloat = 18
        static let fade: CGFloat = 56
    }

    nonisolated static var height: CGFloat { Metrics.height }

    /// The value moved; `isTracking` is true while a finger is still on it.
    var onChange: ((Double, _ isTracking: Bool) -> Void)?
    /// A finger came down on the ruler (true) or lifted (false).
    var onTracking: ((Bool) -> Void)?

    private(set) var value: Double = 0
    private(set) var range: ClosedRange<Double> = 0...1
    /// Where a tap on the readout puts the value.
    private(set) var rest: Double = 0
    private(set) var isTracking = false
    /// How many clicks the ruler has given — a detent reached or passed.
    private(set) var clicks = 0

    private var isTwoSided: Bool { range.lowerBound < 0 }

    private let readout = UILabel()
    private let ruler = Strip()
    private let click = UISelectionFeedbackGenerator()
    private var lastDetent = 0
    private lazy var pan = UIPanGestureRecognizer(target: self, action: #selector(dragged))

    init() {
        super.init(frame: .zero)
        backgroundColor = .clear

        readout.font = .monospacedDigitSystemFont(ofSize: 13, weight: .semibold)
        readout.textAlignment = .center
        readout.textColor = .label
        readout.isAccessibilityElement = false
        readout.isUserInteractionEnabled = true
        readout.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(readoutTapped)))

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

        addGestureRecognizer(pan)

        isAccessibilityElement = true
        accessibilityTraits = .adjustable
        redraw()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Shows one dial: its name, where it can go, where it rests, and where it
    /// is.
    ///
    /// ⚠️ **SILENT.** Stating a value is not a change: no `onChange`, no click.
    func configure(name: String, range: ClosedRange<Double>, rest: Double, value: Double) {
        self.range = range
        self.rest = ValueRuler.clamped(rest, to: range)
        accessibilityLabel = name
        show(value)
    }

    /// Lets go of a drag without announcing anything.
    ///
    /// ⚠️ **THE TOOLS ARE LEAVING UNDER THE FINGER**, and whoever owns the edit
    /// settles it (`MediaEditorEffectsMode.settleTheDrag`). Left tracking, the
    /// ruler would swallow the next touch-down — `setTracking` only speaks on a
    /// change — and the screen would never hear that a finger was down again.
    func abandonDrag() {
        guard isTracking else { return }
        isTracking = false
        // Toggling the recogniser cancels the touch it holds; its `.cancelled`
        // then finds nothing to end.
        pan.isEnabled = false
        pan.isEnabled = true
    }

    /// States the value without announcing it.
    func show(_ newValue: Double) {
        value = ValueRuler.clamped(newValue, to: range)
        lastDetent = ValueRuler.detentIndex(for: value)
        redraw()
    }

    // MARK: - The drag

    @objc private func dragged(_ pan: UIPanGestureRecognizer) {
        switch pan.state {
        case .began:
            beginDrag()
        case .changed:
            let travel = pan.translation(in: self).x
            // Zeroed every sample: `advanced` takes the travel since the last.
            pan.setTranslation(.zero, in: self)
            drag(by: travel)
        case .ended, .cancelled, .failed:
            endDrag()
        default:
            break
        }
    }

    private func beginDrag() {
        click.prepare()
        lastDetent = ValueRuler.detentIndex(for: value)
        setTracking(true)
    }

    private func drag(by travel: CGFloat) {
        move(to: ValueRuler.advanced(value, by: travel, in: range))
    }

    /// ⚠️ **THE LIFT IS A CHANGE TOO** — while a finger is down the screen may
    /// hold back its work, so the settled value is handed over once it is up,
    /// even when it did not move.
    private func endDrag() {
        guard isTracking else { return }
        let settled = ValueRuler.clamped(ValueRuler.settled(value), to: range)
        if settled != value {
            value = settled
            redraw()
        }
        setTracking(false)
        onChange?(value, false)
    }

    private func move(to newValue: Double) {
        guard newValue != value else { return }
        value = newValue
        let detent = ValueRuler.detentIndex(for: value)
        if detent != lastDetent {
            lastDetent = detent
            clicks += 1
            click.selectionChanged()
        }
        redraw()
        onChange?(value, isTracking)
    }

    private func setTracking(_ tracking: Bool) {
        guard tracking != isTracking else { return }
        isTracking = tracking
        onTracking?(tracking)
    }

    @objc private func readoutTapped() {
        guard value != rest else { return }
        move(to: rest)
    }

    override func accessibilityIncrement() { step(by: 0.05) }
    override func accessibilityDecrement() { step(by: -0.05) }

    private func step(by delta: Double) {
        move(to: ValueRuler.clamped(ValueRuler.settled(value + delta), to: range))
    }

    private func redraw() {
        let words = ValueRuler.reading(value, twoSided: isTwoSided)
        readout.text = words.written
        accessibilityValue = words.spoken
        ruler.state = Strip.State(value: value, range: range, rest: rest)
    }

    /// The ticks, drawn rather than assembled — `StraightenDialView`'s reason:
    /// a hundred one-point views would be a hundred layers to composite on
    /// every frame of a drag.
    private final class Strip: UIView {
        struct State: Equatable {
            var value: Double = 0
            var range: ClosedRange<Double> = 0...1
            var rest: Double = 0
        }

        var state = State() {
            didSet { if state != oldValue { setNeedsDisplay() } }
        }

        init() {
            super.init(frame: .zero)
            backgroundColor = .clear
            contentMode = .redraw
            // Registered once, here — `StraightenDialView` records why not in
            // `didMoveToWindow`.
            registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (strip: Strip, _) in
                strip.setNeedsDisplay()
            }
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

        /// ⚠️ **THE VIEW'S OWN TINT, READ HERE** — `UIColor.tintColor` resolved
        /// inside `draw(_:)` does not know which view it is drawing for.
        override func tintColorDidChange() {
            super.tintColorDidChange()
            setNeedsDisplay()
        }

        override func draw(_ rect: CGRect) {
            guard let context = UIGraphicsGetCurrentContext(), bounds.width > 0 else { return }
            let middle = bounds.midX
            let perPercent = ValueRuler.pointsPerPercent
            let valuePercent = state.value * 100
            let low = Int((state.range.lowerBound * 100).rounded())
            let high = Int((state.range.upperBound * 100).rounded())
            let restPercent = state.rest * 100
            let tinted = min(restPercent, valuePercent)...max(restPercent, valuePercent)
            context.setLineWidth(Metrics.tick)
            context.setLineCap(.round)

            for percent in stride(from: low, through: high, by: ValueRuler.tickEvery) {
                let x = middle + CGFloat(Double(percent) - valuePercent) * perPercent
                guard x >= -1, x <= bounds.width + 1 else { continue }
                let isDetent = percent % ValueRuler.detentEvery == 0
                let length = isDetent ? Metrics.longTick : Metrics.shortTick
                let distance = min(x, bounds.width - x)
                let strength = min(1, max(0, distance / Metrics.fade))
                let ink: UIColor = tinted.contains(Double(percent)) && tinted.upperBound > tinted.lowerBound
                    ? tintColor
                    : .label
                let alpha = (isDetent ? 0.85 : 0.45) * strength
                context.setStrokeColor(ink.withAlphaComponent(alpha).cgColor)
                context.move(to: CGPoint(x: x, y: bounds.midY - length / 2))
                context.addLine(to: CGPoint(x: x, y: bounds.midY + length / 2))
                context.strokePath()
            }

            // Where the dial rests: a dot over its tick, so "untouched" can be
            // found without reading the numbers.
            let restX = middle + CGFloat(restPercent - valuePercent) * perPercent
            if restX >= 0, restX <= bounds.width {
                let dot: CGFloat = 4
                context.setFillColor(UIColor.label.withAlphaComponent(0.85).cgColor)
                context.fillEllipse(in: CGRect(
                    x: restX - dot / 2, y: bounds.midY - Metrics.longTick / 2 - dot - 2, width: dot, height: dot
                ))
            }

            // The needle never moves: it is the value that travels.
            context.setLineWidth(2)
            context.setStrokeColor(tintColor.cgColor)
            context.move(to: CGPoint(x: middle, y: bounds.midY - Metrics.needle / 2))
            context.addLine(to: CGPoint(x: middle, y: bounds.midY + Metrics.needle / 2))
            context.strokePath()
        }
    }
}

extension MediaValueRulerView {
    /// Internal for tests: a finger coming down, moving `travel` points, and
    /// lifting — the path a real drag takes.
    func debugBeginDrag() { beginDrag() }
    func debugDrag(by travel: CGFloat) { drag(by: travel) }
    func debugEndDrag() { endDrag() }
    /// Internal for tests: one move straight to `value`, as VoiceOver's adjust
    /// makes — no finger, so announced as settled.
    func debugSet(_ newValue: Double) {
        move(to: ValueRuler.clamped(ValueRuler.settled(newValue), to: range))
    }
    /// Internal for tests: the readout's own words.
    var debugReading: String? { readout.text }
    /// Internal for tests: a tap on the readout.
    func debugTapReadout() { readoutTapped() }
    /// Internal for tests: the ruler strip, to render what it draws.
    var debugStrip: UIView { ruler }
}
