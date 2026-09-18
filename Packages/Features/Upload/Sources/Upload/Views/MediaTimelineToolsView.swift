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
///     0.25s  (0.5s)  1s  1.5s  2s       ← only while the cut carries a kind
///        0:00      0:02      0:04
///   ──────────▓▓▓▓█▓▓▓▓────────────    ← the track, collapsed
///   [⊘ None] [☾ Black] [☀ White]  (✕)   ← MediaTransitionRowView, cards
/// ```
///
/// ⚠️ **THE LENGTHS STAND WHERE THE RATES DO, AND ONLY OVER A KIND.** Opening
/// the row on a plain cut changes no height (charter F28); choosing a kind
/// raises the lengths over the track exactly as the speedometer raises the
/// rates, and "None" lowers them. The rates are never up while a cut is open,
/// so the two never stand together. `onHeightChange` tells the screen, which
/// fits its pages to the band as it does for the rates.
///
/// ⚠️ **IT GROWS THE BAND RATHER THAN COVERING ANYTHING.** A floating panel was
/// the other way, and it would sit exactly where the page indicator is — the band
/// reserves its own room and the canvas is re-laid out around it, which is what
/// `setEditingAccessory` already does for every tenant. A control that lands ON
/// the picture is the plate this band exists to avoid.
@MainActor
final class MediaTimelineToolsView: UIView {
    let speeds = MediaSpeedRowView()
    /// How long the open cut's transition runs — over the track, while the cut
    /// carries a kind.
    let durations = MediaTransitionDurationRowView()
    let track = MediaTimelineTrackView()
    let transitions = MediaTransitionRowView()
    /// The looks one piece can wear — the same row, under the same line.
    let segmentFilters = MediaSegmentFilterRowView()

    /// A length was chosen for the open cut's transition, in played seconds.
    /// Fires on every tap, the length already showing included.
    var onTransitionDuration: ((Double) -> Void)?
    /// The tools changed height — the lengths rose over the track or went
    /// away. The screen lays its pages in their window again.
    var onHeightChange: (() -> Void)?

    /// The cut whose transition is being chosen, if the row is open.
    private(set) var editingSeam: Int?
    /// The piece whose filter is being chosen, if that row is open.
    private(set) var editingPiece: Int?

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
        durations.isHidden = true
        stack.addArrangedSubview(speeds)
        stack.addArrangedSubview(durations)
        stack.addArrangedSubview(track)
        stack.pin(to: self)
        durations.onPick = { [weak self] seconds in self?.onTransitionDuration?(seconds) }

        // ⚠️ **NOT IN THE STACK.** The row stands in room the track already
        // owns — the film's, once collapsed — so the band never changes height
        // for it and the canvas above never moves.
        for row in [transitions as UIView, segmentFilters] {
            row.constrain(in: self) { _ in
                row.leadingAnchor.constraint(equalTo: track.leadingAnchor)
                row.trailingAnchor.constraint(equalTo: track.trailingAnchor)
                row.bottomAnchor.constraint(equalTo: track.bottomAnchor)
                row.heightAnchor.constraint(equalToConstant: MediaTransitionRowView.height)
            }
        }
    }

    /// Collapses the track and opens the filter row on piece `piece`, lighting
    /// the stretch the preview will loop. Returns false when the track refused.
    ///
    /// ⚠️ **NEVER BOTH ROWS.** The screen closes one before opening the other;
    /// this refuses if the transitions row is still up.
    @discardableResult
    func openSegmentFilters(
        forPiece piece: Int, chosen: MediaFilter?, rehearsal: ClosedRange<Double>?, animated: Bool
    ) -> Bool {
        guard editingSeam == nil else { return false }
        track.showRehearsal(rehearsal, window: nil, animated: editingPiece != nil && animated)
        segmentFilters.show(kind: chosen)
        guard editingPiece == nil else {
            segmentFilters.revealChosen(animated: animated)
            editingPiece = piece
            return true
        }
        guard track.setCompact(
            true, bringingUnderTheNeedle: rehearsal?.lowerBound, animated: animated
        ) else { return false }
        editingPiece = piece
        segmentFilters.setOpen(true, animated: animated)
        return true
    }

    /// States what the piece now wears.
    func showSegmentFilter(_ filter: MediaFilter?) {
        segmentFilters.show(kind: filter)
    }

    /// Puts the filter row away and opens the film again.
    func closeSegmentFilters(animated: Bool) {
        guard editingPiece != nil else { return }
        editingPiece = nil
        segmentFilters.setOpen(false, animated: animated)
        track.setCompact(false, animated: animated)
    }

    /// Collapses the track and opens the row on cut `seam`, lighting the stretch
    /// the preview will loop. Returns false when the track refused — a finger is
    /// holding something on it.
    ///
    /// `seconds` is how long the cut's transition runs and `longest` the most
    /// its two pieces can give (`MediaTimelining.transitionSeconds` and
    /// `.longestTransition`); left out, the lengths show the standard and
    /// refuse nothing.
    @discardableResult
    func openTransitions(
        atSeam seam: Int, chosen: VideoTransitionKind?, seconds: Double? = nil, longest: Double? = nil,
        rehearsal: ClosedRange<Double>?, window: ClosedRange<Double>?, animated: Bool
    ) -> Bool {
        guard editingPiece == nil else { return false }
        track.showRehearsal(rehearsal, window: window, animated: editingSeam != nil && animated)
        transitions.show(kind: chosen)
        showLength(seconds: seconds, longest: longest)
        guard editingSeam == nil else {
            transitions.revealChosen(animated: animated)
            editingSeam = seam
            offerDurations(chosen != nil, animated: animated)
            return true
        }
        guard track.setCompact(
            true, bringingUnderTheNeedle: rehearsal?.lowerBound, animated: animated
        ) else { return false }
        editingSeam = seam
        transitions.setOpen(true, animated: animated)
        offerDurations(chosen != nil, animated: animated)
        return true
    }

    /// States what the cut now carries — its kind, and how long it runs — and
    /// the stretch that shows it.
    func showTransition(
        _ kind: VideoTransitionKind?, seconds: Double? = nil, longest: Double? = nil,
        rehearsal: ClosedRange<Double>?, window: ClosedRange<Double>?
    ) {
        transitions.show(kind: kind)
        showLength(seconds: seconds, longest: longest)
        track.showRehearsal(rehearsal, window: window, animated: true)
        if editingSeam != nil { offerDurations(kind != nil, animated: true) }
    }

    /// Puts the row away and opens the film again.
    func closeTransitions(animated: Bool) {
        guard editingSeam != nil else { return }
        editingSeam = nil
        transitions.setOpen(false, animated: animated)
        track.setCompact(false, animated: animated)
        offerDurations(false, animated: animated)
    }

    /// Whether the lengths are standing over the track.
    var isOfferingDurations: Bool { !durations.isHidden }

    private func showLength(seconds: Double?, longest: Double?) {
        durations.show(
            seconds: seconds ?? VideoTransitionKind.standardSeconds,
            longest: longest ?? MediaTimelining.transitionLengths.last ?? VideoTransitionKind.standardSeconds
        )
    }

    /// Raises the lengths over the track, or takes them away — and says so,
    /// since the band's height is the screen's to follow.
    ///
    /// ⚠️ **THE FADE IS ON THE WAY IN ONLY, AND THE FROM-VALUE IS SET FIRST** —
    /// the rate chips' reason (`isOfferingSpeeds`).
    private func offerDurations(_ offered: Bool, animated: Bool) {
        guard offered != isOfferingDurations else { return }
        durations.isHidden = !offered
        if offered, animated, window != nil {
            durations.alpha = 0
            UIView.animate(withDuration: 0.2) { self.durations.alpha = 1 }
        } else {
            durations.alpha = 1
        }
        onHeightChange?()
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
