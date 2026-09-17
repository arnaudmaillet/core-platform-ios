import DesignSystem
import UIKit

/// One dial being turned: a glass close button, the dial's name over its
/// value, and a slider.
///
/// ```
/// (✕)  Brightness   ━━━━━━━━━━━●━━━━━━━━━
///      +23
/// ```
///
/// ⚠️ **ZERO IS WHERE A TWO-SIDED DIAL RESTS, AND THE TRACK SAYS SO.** A
/// brightness of -40 is as much an edit as +40; a track filled from its left
/// end would draw -40 as "a little" and +40 as "a lot". iOS 26's
/// `trackConfiguration` fills from `neutralValue` instead, so the fill grows
/// out of the middle both ways. A one-sided dial (sharpness, an effect's
/// strength) keeps its neutral at the left end, where 0 already is.
///
/// ⚠️ **THE VALUE LABEL IS THE RESET.** A double tap on it puts the dial back
/// to zero — the slider alone cannot land on exactly zero, and
/// `LookAdjustments` snaps only what is within 0.005 of it.
///
/// ⚠️ **A TICK AT ZERO, AND ONLY WHEN IT IS CROSSED OR REACHED.** A haptic on
/// every value would buzz for the whole drag; one on the way through zero is
/// how a finger finds "untouched" without looking.
@MainActor
final class MediaValueSliderRow: UIView {
    private enum Metrics {
        static let close: CGFloat = 36
        static let label: CGFloat = 88
    }

    /// The value moved; `isTracking` is true while a finger is still on it.
    var onChange: ((Double, _ isTracking: Bool) -> Void)?
    /// A finger came down on the slider (true) or lifted (false).
    var onTracking: ((Bool) -> Void)?
    /// The close button was tapped.
    var onClose: (() -> Void)?

    private let glass = UIVisualEffectView(effect: UIGlassEffect(style: .regular))
    private let closeButton = UIButton(type: .custom)
    private let title = UILabel()
    private let valueLabel = UILabel()
    private let slider = UISlider()
    private let ticker = UISelectionFeedbackGenerator()

    private var range: ClosedRange<Double> = 0...1
    private var isTwoSided: Bool { range.lowerBound < 0 }
    private(set) var value: Double = 0
    private(set) var isTracking = false
    /// How many times the value came to or through zero — the haptic's count.
    private(set) var neutralTicks = 0

    init() {
        super.init(frame: .zero)
        backgroundColor = .clear

        glass.clipsToBounds = true
        glass.cornerConfiguration = .capsule()
        glass.translatesAutoresizingMaskIntoConstraints = false
        closeButton.setImage(
            UIImage(
                systemName: MediaEffectsCatalog.closeGlyph,
                withConfiguration: UIImage.SymbolConfiguration(pointSize: 13, weight: .semibold)
            ),
            for: .normal
        )
        closeButton.tintColor = .label
        closeButton.addAction(UIAction { [weak self] _ in self?.onClose?() }, for: .primaryActionTriggered)
        glass.contentView.addSubview(closeButton)
        closeButton.pin(to: glass.contentView)

        title.font = .systemFont(ofSize: 13, weight: .semibold)
        title.textColor = .label
        title.adjustsFontSizeToFitWidth = true
        title.minimumScaleFactor = 0.8
        valueLabel.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        valueLabel.textColor = .secondaryLabel
        // ⚠️ A LABEL TAKES NO TOUCH UNTIL IT IS TOLD TO, and the double tap
        // below is the only way back to exactly zero.
        valueLabel.isUserInteractionEnabled = true
        let reset = UITapGestureRecognizer(target: self, action: #selector(resetTapped))
        reset.numberOfTapsRequired = 2
        valueLabel.addGestureRecognizer(reset)
        let words = UIStackView(arrangedSubviews: [title, valueLabel])
        words.axis = .vertical
        words.spacing = 0
        words.translatesAutoresizingMaskIntoConstraints = false

        slider.minimumTrackTintColor = .label
        slider.translatesAutoresizingMaskIntoConstraints = false
        slider.addAction(UIAction { [weak self] _ in self?.sliderMoved() }, for: .valueChanged)
        slider.addAction(UIAction { [weak self] _ in self?.setTracking(true) }, for: .touchDown)
        slider.addAction(
            UIAction { [weak self] _ in self?.setTracking(false) },
            for: [.touchUpInside, .touchUpOutside, .touchCancel]
        )
        slider.accessibilityCustomActions = [
            UIAccessibilityCustomAction(name: "Reset") { [weak self] _ in
                self?.resetTapped()
                return true
            }
        ]

        addSubview(glass)
        addSubview(words)
        addSubview(slider)
        NSLayoutConstraint.activate([
            glass.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Spacing.lg),
            glass.centerYAnchor.constraint(equalTo: centerYAnchor),
            glass.widthAnchor.constraint(equalToConstant: Metrics.close),
            glass.heightAnchor.constraint(equalToConstant: Metrics.close),
            words.leadingAnchor.constraint(equalTo: glass.trailingAnchor, constant: Spacing.md),
            words.centerYAnchor.constraint(equalTo: centerYAnchor),
            words.widthAnchor.constraint(equalToConstant: Metrics.label),
            slider.leadingAnchor.constraint(equalTo: words.trailingAnchor, constant: Spacing.sm),
            slider.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Spacing.lg),
            slider.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Shows one dial: its name, where it can go, and where it is.
    ///
    /// ⚠️ **SILENT.** Stating a value is not a change: no `onChange`, no tick.
    func configure(title text: String, closeLabel: String, range: ClosedRange<Double>, value: Double) {
        self.range = range
        title.text = text
        closeButton.accessibilityLabel = closeLabel
        slider.accessibilityLabel = text
        slider.minimumValue = Float(range.lowerBound)
        slider.maximumValue = Float(range.upperBound)
        // ⚠️ **`allowsTickValuesOnly: false`, OR THE SLIDER SNAPS TO ITS TICKS**
        // — and with no ticks there would be nowhere to go. The configuration is
        // here for the fill that grows out of `neutralValue`.
        slider.trackConfiguration = UISlider.TrackConfiguration(
            allowsTickValuesOnly: false,
            neutralValue: 0,
            enabledRange: Float(range.lowerBound)...Float(range.upperBound),
            ticks: []
        )
        show(value)
    }

    /// States the value without announcing it.
    func show(_ newValue: Double) {
        value = min(max(newValue, range.lowerBound), range.upperBound)
        slider.value = Float(value)
        spell()
    }

    /// What the value label says, and what VoiceOver says: a whole percentage,
    /// signed on a two-sided dial.
    static func spelled(_ value: Double, twoSided: Bool) -> (written: String, spoken: String) {
        let whole = Int((value * 100).rounded())
        guard twoSided, whole != 0 else { return ("\(whole)", "\(whole)") }
        return whole > 0 ? ("+\(whole)", "plus \(whole)") : ("−\(-whole)", "minus \(-whole)")
    }

    private func spell() {
        let words = Self.spelled(value, twoSided: isTwoSided)
        valueLabel.text = words.written
        slider.accessibilityValue = words.spoken
    }

    private func sliderMoved() {
        let previous = value
        value = Double(slider.value)
        if crossesZero(from: previous, to: value) {
            neutralTicks += 1
            ticker.selectionChanged()
        }
        spell()
        onChange?(value, isTracking)
    }

    /// ⚠️ **ARRIVING AT ZERO COUNTS; LEAVING IT DOES NOT** — or a drag that
    /// starts at rest would tick at its first move.
    private func crossesZero(from old: Double, to new: Double) -> Bool {
        let snap = 0.005
        let wasZero = abs(old) < snap, isZero = abs(new) < snap
        if isZero { return !wasZero }
        return !wasZero && (old < 0) != (new < 0)
    }

    private func setTracking(_ tracking: Bool) {
        guard tracking != isTracking else { return }
        isTracking = tracking
        if tracking { ticker.prepare() }
        onTracking?(tracking)
        // ⚠️ **THE LIFT IS A CHANGE TOO.** While a finger is down the screen may
        // hold back its work; the last value has to be handed over once it is up.
        if !tracking { onChange?(value, false) }
    }

    @objc private func resetTapped() {
        guard value != 0 else { return }
        show(0)
        neutralTicks += 1
        ticker.selectionChanged()
        onChange?(0, false)
    }

    /// Internal for tests: the slider itself, to move it the way a finger does.
    var debugSlider: UISlider { slider }
    /// Internal for tests: what the value label reads.
    var debugValueText: String? { valueLabel.text }
    /// Internal for tests: a double tap on the value label.
    func debugDoubleTapValue() { resetTapped() }
    /// Internal for tests: the close button.
    func debugTapClose() { onClose?() }
}
