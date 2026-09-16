import DesignSystem
import UIKit

/// The band's trim tenant: the film, with the rate chips standing above it when
/// they have been asked for.
///
/// ```
///     0.25×  0.5×  (1×)  2×  4×      ← only while the speedometer is lit
///  ────────────────────────────────
///        0:00      0:02      0:04
///   ░░░░┃▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓┃░░░░
/// ```
///
/// ⚠️ **A HOST, SO THE TRACK STAYS ONE THING.** The chips could have been a row
/// inside `MediaTimelineTrackView`, and that view's every coordinate is measured
/// from its own top edge — the needle runs the full height, the ruler sits at
/// zero, the strip one rail below it. A row growing out of the top would shift
/// all of that by a number every one of those lines would have to learn. The
/// track keeps its geometry; this stacks a second control on top of it.
///
/// ⚠️ **IT GROWS THE BAND RATHER THAN COVERING ANYTHING.** A floating panel was
/// the other way, and it would sit exactly where the page indicator is — the band
/// reserves its own room and the canvas is re-laid out around it, which is what
/// `setEditingAccessory` already does for every tenant. A control that lands ON
/// the picture is the plate this band exists to avoid.
@MainActor
final class MediaTimelineToolsView: UIView {
    let speeds = MediaSpeedRowView()
    let track = MediaTimelineTrackView()

    private let stack = UIStackView()

    init() {
        super.init(frame: .zero)
        backgroundColor = .clear

        stack.axis = .vertical
        stack.alignment = .fill
        stack.spacing = Spacing.sm
        // ⚠️ **HIDDEN, NOT REMOVED.** A `UIStackView` takes a hidden arranged
        // subview out of its own layout AND drops the spacing that went with it,
        // so the band's height is right in both states without a constraint being
        // switched by hand — and `isHidden` is animatable, which a rebuilt
        // hierarchy is not.
        speeds.isHidden = true
        stack.addArrangedSubview(speeds)
        stack.addArrangedSubview(track)
        stack.pin(to: self)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Whether the rate chips are standing open.
    var isOfferingSpeeds: Bool {
        get { !speeds.isHidden }
        set {
            guard newValue != isOfferingSpeeds else { return }
            speeds.isHidden = !newValue
            // ⚠️ **THE FADE IS ON THE WAY IN ONLY, AND THE FROM-VALUE IS SET
            // FIRST.** `UIView.animate` reads the from-value off the presentation
            // layer, so staging the END value and then animating to the same
            // value animates nothing at all — `uiview-animate-from-value-trap`
            // records this repository paying for exactly that with a cell's
            // `alpha`. On the way OUT `isHidden` has already taken the row out of
            // the layout, so there is nothing left to fade.
            guard newValue else { return }
            speeds.alpha = 0
            UIView.animate(withDuration: 0.2) { self.speeds.alpha = 1 }
        }
    }
}
