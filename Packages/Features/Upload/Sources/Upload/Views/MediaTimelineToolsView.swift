import DesignSystem
import MediaPlayback
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
/// While a cut's transition is being chosen the film collapses into a line and
/// the transitions row takes the room it gave up — the band keeps its height:
///
/// ```
///        0:00      0:02      0:04
///   ──────────▓▓▓▓█▓▓▓▓────────────    ← the track, collapsed
///   [⊘ None] [☾ Black] [☀ White]  (✕)   ← MediaTransitionRowView, cards
/// ```
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
    let transitions = MediaTransitionRowView()

    /// The cut whose transition is being chosen, if the row is open.
    private(set) var editingSeam: Int?

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

        // ⚠️ **NOT IN THE STACK.** The row stands in room the track already
        // owns — the film's, once collapsed — so the band never changes height
        // for it and the canvas above never moves.
        transitions.constrain(in: self) { _ in
            transitions.leadingAnchor.constraint(equalTo: track.leadingAnchor)
            transitions.trailingAnchor.constraint(equalTo: track.trailingAnchor)
            transitions.bottomAnchor.constraint(equalTo: track.bottomAnchor)
            transitions.heightAnchor.constraint(equalToConstant: MediaTransitionRowView.height)
        }
    }

    /// Collapses the track and opens the row on cut `seam`, lighting the stretch
    /// the preview will loop. Returns false when the track refused — a finger is
    /// holding something on it.
    @discardableResult
    func openTransitions(
        atSeam seam: Int, chosen: VideoTransitionKind?,
        rehearsal: ClosedRange<Double>?, window: ClosedRange<Double>?, animated: Bool
    ) -> Bool {
        track.showRehearsal(rehearsal, window: window, animated: editingSeam != nil && animated)
        transitions.show(kind: chosen)
        guard editingSeam == nil else {
            transitions.revealChosen(animated: animated)
            editingSeam = seam
            return true
        }
        guard track.setCompact(
            true, bringingUnderTheNeedle: rehearsal?.lowerBound, animated: animated
        ) else { return false }
        editingSeam = seam
        transitions.setOpen(true, animated: animated)
        return true
    }

    /// States what the cut now carries, and the stretch that shows it.
    func showTransition(
        _ kind: VideoTransitionKind?, rehearsal: ClosedRange<Double>?, window: ClosedRange<Double>?
    ) {
        transitions.show(kind: kind)
        track.showRehearsal(rehearsal, window: window, animated: true)
    }

    /// Puts the row away and opens the film again.
    func closeTransitions(animated: Bool) {
        guard editingSeam != nil else { return }
        editingSeam = nil
        transitions.setOpen(false, animated: animated)
        track.setCompact(false, animated: animated)
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
