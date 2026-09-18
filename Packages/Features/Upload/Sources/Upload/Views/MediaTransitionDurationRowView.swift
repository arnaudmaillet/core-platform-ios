import DesignSystem
import MediaPlayback
import UIKit

/// The lengths the transition at a cut can be given.
///
/// ```
///   0.25s   ( 0.5s )   1s   1.5s   2s
///  ────────────────────────────────────
///        0:00      0:02      0:04
///   ──────────▓▓▓▓█▓▓▓▓────────────     ← the track, collapsed
///   [⊘ None] [☾ Black] [☀ White]  (✕)   ← the transitions
/// ```
///
/// ⚠️ **CHIPS, NOT A RULER — AND THE RATE CHIPS' SHAPE, IN THE RATE CHIPS'
/// PLACE.** Three reasons, all measured against the alternatives:
/// - **A length is a new film.** Every change builds a new preview item that
///   lands on the rehearsed stretch — a ruler dragged across it would either
///   rebuild sixty times a second or show nothing until the finger lifts, and
///   a transition is judged by watching it, not by reading a number. A tap is
///   one new item, exactly as choosing a kind is.
/// - **The band has no room for a ruler.** `MediaValueRulerView` is 56pt and the
///   collapsed track keeps every one of its 75 (charter F28); these chips are
///   28, the height the rate row already adds over the track — and the rate row
///   is never up while a cut is open, so the two share the slot and the band
///   grows by exactly what it grows for a rate.
/// - **The ruler reads percentages.** A second spelled "50%" is a unit the
///   author would have to translate; the chips write seconds.
///
/// ⚠️ **A LENGTH THE PIECES CANNOT GIVE IS SHOWN, AND REFUSED.** A transition
/// borrows half its length from each piece at its cut, so a cut between two
/// short pieces cannot carry two seconds (`MediaTimelining.longestTransition`).
/// Those chips stay in the row — the row does not change shape from one cut to
/// the next — but are dimmed and take no tap.
///
/// ⚠️ **INK, NOT A PLATE — the band's rule, as `MediaSpeedRowView` states it.**
/// The chosen length is a white capsule, the white the chosen transition card
/// is drawn in: the two are saying the same thing about the same cut.
@MainActor
final class MediaTransitionDurationRowView: UIView {
    /// A length was chosen, in played seconds. Fires on every tap, including
    /// the length already showing — it replays the transition.
    var onPick: ((Double) -> Void)?

    private enum Metrics {
        static let chip: CGFloat = 28
        /// Wide enough for "0.25s" in the chip's own type, with air either side.
        static let chipWidth: CGFloat = 52
        /// What a length the pieces cannot give is dimmed to.
        static let refused: CGFloat = 0.3
    }

    nonisolated static var height: CGFloat { Metrics.chip }

    private let row = UIStackView()
    private var chips: [UIButton] = []
    private var showing = VideoTransitionKind.standardSeconds
    private var longest = MediaTimelining.transitionLengths.last ?? VideoTransitionKind.standardSeconds

    init() {
        super.init(frame: .zero)
        backgroundColor = .clear

        row.axis = .horizontal
        row.alignment = .center
        row.distribution = .equalSpacing
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.centerXAnchor.constraint(equalTo: centerXAnchor),
            row.topAnchor.constraint(equalTo: topAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor),
            row.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: Spacing.md),
            row.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -Spacing.md)
        ])

        chips = MediaTimelining.transitionLengths.map { seconds in
            let chip = UIButton(type: .custom)
            chip.setTitle(MediaTimelining.transitionLengthLabel(seconds), for: .normal)
            chip.titleLabel?.font = .monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
            chip.accessibilityLabel = "Transition lasts \(Self.spoken(seconds))"
            chip.layer.cornerRadius = Metrics.chip / 2
            chip.layer.cornerCurve = .continuous
            chip.addAction(
                UIAction { [weak self] _ in self?.onPick?(seconds) }, for: .primaryActionTriggered
            )
            // Gives under the finger and ticks on a tap, as every button of
            // the editing tools does (`PressFeedback`).
            PressFeedback.attach(to: chip)
            chip.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                chip.widthAnchor.constraint(equalToConstant: Metrics.chipWidth),
                chip.heightAnchor.constraint(equalToConstant: Metrics.chip)
            ])
            row.addArrangedSubview(chip)
            return chip
        }
        row.spacing = Spacing.xs
        dress()
        heightAnchor.constraint(equalToConstant: Metrics.chip).isActive = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// States how long the cut's transition runs, and the longest its two
    /// pieces can give — without announcing anything.
    func show(seconds: Double, longest: Double) {
        guard abs(seconds - showing) > 0.0005 || abs(longest - self.longest) > 0.0005 else { return }
        showing = seconds
        self.longest = longest
        dress()
    }

    private func dress() {
        for (chip, seconds) in zip(chips, MediaTimelining.transitionLengths) {
            let isShowing = abs(seconds - showing) < 0.0005
            let isReachable = seconds <= longest + 0.0005
            chip.isEnabled = isReachable
            chip.alpha = isReachable ? 1 : Metrics.refused
            chip.backgroundColor = isShowing ? .white : .clear
            chip.setTitleColor(isShowing ? .black : .white, for: .normal)
            // ⚠️ **A CHOSEN LENGTH THE PIECES CAN NO LONGER GIVE KEEPS ITS INK.**
            // It is dimmed with the other refused ones, but white on its white
            // fill it was a blank pill — and the one chip saying what the cut
            // carries said nothing. A trim after the choice, or a neighbour at
            // 4x, gets there.
            chip.setTitleColor(isShowing ? .black : .white, for: .disabled)
            // ⚠️ **A SHADOW ON THE UNCHOSEN ONES ONLY** — `MediaSpeedRowView`'s
            // reason: white ink on a photograph needs the lift, and a shadow
            // under a filled capsule reads as a plate.
            chip.titleLabel?.layer.shadowColor = UIColor.black.cgColor
            chip.titleLabel?.layer.shadowOpacity = isShowing ? 0 : 0.35
            chip.titleLabel?.layer.shadowRadius = 2
            chip.titleLabel?.layer.shadowOffset = .zero
            chip.accessibilityTraits = isShowing ? [.button, .selected] : [.button]
        }
    }

    /// What VoiceOver says for a length: "half a second", "1 second",
    /// "1.5 seconds".
    static func spoken(_ seconds: Double) -> String {
        if abs(seconds - 0.25) < 0.0005 { return "a quarter of a second" }
        if abs(seconds - 0.5) < 0.0005 { return "half a second" }
        if abs(seconds - 1) < 0.0005 { return "1 second" }
        return String(format: "%g seconds", (seconds * 100).rounded() / 100)
    }
}

#if DEBUG
extension MediaTransitionDurationRowView {
    /// Internal for tests: the length each chip offers, in the order shown.
    var debugTitles: [String] { chips.compactMap { $0.title(for: .normal) } }
    /// Internal for tests: every control that should give under a finger.
    var debugPressables: [UIControl] { chips }
    /// Internal for tests: which chip is DRAWN as the current one — read off
    /// its fill, not off the value beside it.
    var debugChosen: [String] {
        chips.filter { $0.backgroundColor == .white }.compactMap { $0.title(for: .normal) }
    }
    /// Internal for tests: the chips whose label can be read against their
    /// own fill, in the state they are in.
    var debugLegible: [String] {
        chips.filter { chip in
            let ink = chip.titleColor(for: chip.isEnabled ? .normal : .disabled)
            return ink != (chip.backgroundColor ?? .clear)
        }.compactMap { $0.title(for: .normal) }
    }
    /// Internal for tests: the chips that take a tap.
    var debugEnabled: [String] {
        chips.filter(\.isEnabled).compactMap { $0.title(for: .normal) }
    }
    /// Internal for tests: taps a chip exactly as a finger would — a disabled
    /// one does nothing, as it would under a finger.
    func debugTap(seconds: Double) {
        guard let index = MediaTimelining.transitionLengths.firstIndex(where: { abs($0 - seconds) < 0.0005 }),
              chips[index].isEnabled
        else { return }
        chips[index].sendActions(for: .primaryActionTriggered)
    }
}
#endif
