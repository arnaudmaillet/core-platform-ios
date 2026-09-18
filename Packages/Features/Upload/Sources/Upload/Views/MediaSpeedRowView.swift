import DesignSystem
import UIKit

/// The rates a piece of the clip can play at.
///
/// ```
///   0.25×   0.5×   ( 1× )   2×   4×
/// ```
///
/// ⚠️ **INK, NOT A PLATE — the band's rule, stated by every tenant it has.** The
/// canvas runs full-bleed underneath and a surface here would cut the picture in
/// two. The chosen rate is a white capsule because white is what the selection
/// on the track is drawn in: the two are saying the same thing about the same
/// piece, and a second colour would read as a second meaning.
///
/// ⚠️ **IT ACTS ON THE PIECE UNDER THE NEEDLE, AND KNOWS NOTHING ABOUT WHICH ONE
/// THAT IS.** The screen asks `MediaTimelining` that question; this row offers
/// five numbers and announces the one that was touched. A row that resolved the
/// piece itself would be a second implementation of `pieceIndex`, which is the
/// duplication this package has already paid for in `moved`.
@MainActor
final class MediaSpeedRowView: UIView {
    /// A rate was chosen. Fires on every tap, including the rate already showing
    /// — re-stating a value is not an error and the screen simply stores it again.
    var onPick: ((Double) -> Void)?

    private enum Metrics {
        static let chip: CGFloat = 28
        /// Wide enough for "0.25×" in the chip's own type, with air either side.
        static let chipWidth: CGFloat = 52
    }

    nonisolated static var height: CGFloat { Metrics.chip }

    private let row = UIStackView()
    private var chips: [UIButton] = []
    private var showing: Double = 1

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

        chips = MediaTimelining.rates.map { rate in
            let chip = UIButton(type: .custom)
            chip.setTitle(MediaTimelining.rateLabel(rate), for: .normal)
            chip.titleLabel?.font = .monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
            chip.accessibilityLabel = "Play at \(MediaTimelining.rateLabel(rate))"
            chip.layer.cornerRadius = Metrics.chip / 2
            chip.layer.cornerCurve = .continuous
            chip.addAction(
                UIAction { [weak self] _ in self?.onPick?(rate) }, for: .primaryActionTriggered
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

    /// States which rate the piece under the needle is playing at.
    func show(rate: Double) {
        guard abs(rate - showing) > 0.001 else { return }
        showing = rate
        dress()
    }

    private func dress() {
        for (chip, rate) in zip(chips, MediaTimelining.rates) {
            let isShowing = abs(rate - showing) < 0.001
            chip.backgroundColor = isShowing ? .white : .clear
            chip.setTitleColor(isShowing ? .black : .white, for: .normal)
            // ⚠️ **A SHADOW ON THE UNCHOSEN ONES ONLY.** They are white ink on a
            // photograph and need the lift; the chosen one is a white capsule,
            // and a shadow under a filled shape reads as a plate — the one thing
            // the band forbids.
            chip.titleLabel?.layer.shadowColor = UIColor.black.cgColor
            chip.titleLabel?.layer.shadowOpacity = isShowing ? 0 : 0.35
            chip.titleLabel?.layer.shadowRadius = 2
            chip.titleLabel?.layer.shadowOffset = .zero
            chip.accessibilityTraits = isShowing ? [.button, .selected] : [.button]
        }
    }
}

#if DEBUG
extension MediaSpeedRowView {
    /// Internal for tests: the rate each chip offers, in the order shown.
    var debugTitles: [String] { chips.compactMap { $0.title(for: .normal) } }
    /// Internal for tests: every control that should give under a finger.
    var debugPressables: [UIControl] { chips }
    /// Internal for tests: which chip is drawn as the current one.
    var debugChosen: String? {
        zip(chips, MediaTimelining.rates)
            .first { abs($0.1 - showing) < 0.001 }?.0.title(for: .normal)
    }
    /// Internal for tests: taps a chip exactly as a finger would.
    func debugTap(rate: Double) {
        guard let index = MediaTimelining.rates.firstIndex(where: { abs($0 - rate) < 0.001 })
        else { return }
        chips[index].sendActions(for: .primaryActionTriggered)
    }
}
#endif
