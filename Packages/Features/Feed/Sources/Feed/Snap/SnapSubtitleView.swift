import DesignSystem
import UIKit

/// The subtitle zone: semantic comments rendered one at a time, movie-
/// subtitle style — fade in, hold, fade out — directly above the reaction
/// band. The conveyor drifts; this zone breathes.
///
/// # Look
/// A left-aligned translucent pill hugging its text, one typographic tier
/// below the caption (footnote/medium vs the caption's body): the caption is
/// the post's voice and stays dominant; cues stack on the same leading axis
/// as the caption below, one column of text up the page. The pill (not a
/// glyph shadow) carries legibility over bright or moving video.
///
/// # Engine
/// One `CAKeyframeAnimation` on `opacity` per cue segment, whose completion
/// advances the wrap-around queue. Deliberately no timers: the band's
/// device triage proved wall-clock cadence desyncs from the layer clock
/// under percent-driven transitions, and a single animation per segment
/// keeps pacing and rendering on the same clock. Steady state costs the
/// compositor one alpha-blended pill layer; the main thread is touched once
/// per cue to rasterize the next text (double-buffered labels, off the
/// fade path).
///
/// # Transitions: fade vs hard cut
/// Each cue handoff is planned up front (`plannedTransitions`): the default
/// is the subtitle idiom — fade out, dark beat, fade in. But when two cues
/// sit closer on the playback timeline than `hardCutThreshold`, that cycle
/// compresses into a stroboscopic flash, so the handoff becomes a HARD CUT:
/// the outgoing segment ends at full opacity and *fills forwards* (not
/// removed), and its completion swaps the text on the same label and
/// replaces the filled animation on the same key in one transaction. The
/// pill never leaves 100% opacity and — critically — there is no frame
/// where an ended animation's removal exposes the invisible model value.
/// Cues without timestamps (v1 even pacing) always fade. Filled segments
/// stay backgrounding-safe: stripping animations drops the layer to its
/// model opacity of 0, hiding the zone rather than stranding a pill.
///
/// # Timing seam
/// Cues carry an optional playback-timeline anchor (`SubtitleCue.at`),
/// unused today: v1 paces evenly from activation, which is also the
/// permanent fallback for image posts (no timeline). When the API delivers
/// timestamps, scheduling moves onto the player clock; this view keeps
/// rendering "the current cue" either way.
///
/// # Lifecycle
/// Settle-scoped (active), deliberately unlike the band's visibility scope:
/// subtitles belong to the playback timeline, and a page dragged halfway in
/// has no playing media — its zone stays blank until the page settles, the
/// same gate video uses. Hard stop/start with a generation counter (the
/// band's doctrine): deactivation removes animations and zeroes both labels'
/// model opacity, so backgrounding (which strips CA animations) can never
/// strand a visible stale cue. Fade-only motion, so the zone stays on under
/// Reduce Motion even while the conveyor hides.
final class SnapSubtitleView: UIView {
    static let fadeDuration: TimeInterval = 0.10
    static let holdDuration: TimeInterval = 3.5
    /// Dark beat between consecutive cues — the subtitle idiom needs a gap
    /// so replacement reads as a new line, not a text mutation. Also the
    /// lead-in delay after activation.
    static let interCueGap: TimeInterval = 0.35
    /// The flicker floor for timestamped cues: a delta shorter than one
    /// complete dark cycle (fade-out + dark beat + fade-in) cannot fade
    /// without reading as a flash, so handoffs under it hard-cut instead.
    static var hardCutThreshold: TimeInterval { interCueGap + 2 * fadeDuration }

    /// How one cue hands off to the next.
    enum CueTransition {
        /// Fade out, dark beat, fade in — the subtitle idiom.
        case fade
        /// Instant text swap at full opacity; the pill never blinks.
        case cut
    }

    private var cues: [SubtitleCue] = []
    /// Element `i` is the planned handoff cue `i` → cue `(i + 1) % count`,
    /// derived once per cue list from timestamp deltas.
    private var transitions: [CueTransition] = []
    private var nextIndex = 0
    /// Mirrors the owning cell's settled-active state; content may arrive
    /// before or after it, so both paths funnel into `startIfNeeded`.
    private var isActive = false
    private var isCycling = false
    /// Invalidates stale CA completions across stops — completions fire even
    /// for removed animations, and a stale one must not advance a cycle a
    /// newer owner already reset.
    private var generation = 0
    /// Double buffer: the next cue rasterizes on the off-screen label while
    /// the current one holds, so text drawing never lands mid-fade.
    private let labels = [SubtitlePillLabel(), SubtitlePillLabel()]
    private var frontLabelIndex = 0

    override init(frame: CGRect) {
        super.init(frame: frame)
        isHidden = true
        isUserInteractionEnabled = false // taps fall through to play/pause
        for label in labels {
            label.numberOfLines = 2
            label.lineBreakMode = .byTruncatingTail
            label.textAlignment = .left
            label.layer.opacity = 0
            // The pill lives on the label's own layer so the cue animation
            // still touches exactly one layer (background and glyphs fade as
            // a unit). Deliberately no `masksToBounds`: `backgroundColor`
            // clips to the radius on its own, the text never reaches the
            // corners (it's inset — see `SubtitlePillLabel`), and an
            // unmasked layer keeps the opacity fade a direct composite.
            label.layer.backgroundColor = UIColor.black.withAlphaComponent(0.45).cgColor
            label.layer.cornerRadius = 12 // fixed, so 1- and 2-line cues share one shape
            label.layer.cornerCurve = .continuous
            // Leading-pinned and content-hugging: the pill hugs its text,
            // growing rightward, so its left edge locks to the caption's
            // leading margin — cues and caption share one text axis. Bottom-
            // pinned so a one-line cue sits where a two-line cue's last
            // line does — the subtitle baseline never jumps.
            label.constrain(in: self) { parent in
                label.leadingAnchor.constraint(equalTo: parent.leadingAnchor)
                label.trailingAnchor.constraint(lessThanOrEqualTo: parent.trailingAnchor)
                label.bottomAnchor.constraint(equalTo: parent.bottomAnchor)
            }
        }
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { (self: SnapSubtitleView, _) in
            self.invalidateIntrinsicContentSize()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// A fixed two-line slot: the zone's geometry is content-independent, so
    /// cue arrival, length, or absence can never move anything around it —
    /// and the flight replica (which never receives cues) occupies identical
    /// space by construction.
    override var intrinsicContentSize: CGSize {
        let insets = SubtitlePillLabel.textInsets
        return CGSize(
            width: UIView.noIntrinsicMetric,
            height: ceil(UIFont.preferredFont(forTextStyle: .footnote).lineHeight * 2)
                + insets.top + insets.bottom
        )
    }

    // MARK: - Content & lifecycle

    /// Replaces the wrap-around cue list. Empty (post below the engagement
    /// gate, or nothing loaded yet) hides the zone. Re-applying an identical
    /// list is a no-op so cache re-emissions don't restart the cycle.
    func setCues(_ newCues: [SubtitleCue]) {
        guard newCues != cues else { return }
        stopCycle()
        cues = newCues
        transitions = Self.plannedTransitions(for: newCues)
        nextIndex = 0
        isHidden = newCues.isEmpty
        startIfNeeded()
    }

    /// Plans every handoff from the cues' timeline anchors: closer than
    /// `hardCutThreshold` → `.cut`, otherwise (or when either side has no
    /// timestamp — v1's even pacing) → `.fade`. The wrap-around restart
    /// always fades: the loop rejoining its start is a new pass, not a
    /// dense neighbor.
    static func plannedTransitions(for cues: [SubtitleCue]) -> [CueTransition] {
        cues.indices.map { index in
            let next = index + 1
            guard next < cues.count, // wrap boundary → .fade
                  let currentAt = cues[index].at, let nextAt = cues[next].at,
                  nextAt - currentAt < hardCutThreshold
            else { return .fade }
            return .cut
        }
    }

    /// Follows the page's settled-active state (the same seam as playback),
    /// NOT visibility — see the class doc.
    func setActive(_ active: Bool) {
        guard active != isActive else { return }
        isActive = active
        if active {
            startIfNeeded()
        } else {
            stopCycle()
        }
    }

    /// Clears cue content and state (cell reuse).
    func reset() {
        stopCycle()
        cues = []
        transitions = []
        nextIndex = 0
        isActive = false
        isHidden = true
    }

    private func startIfNeeded() {
        guard isActive, !cues.isEmpty, !isCycling else { return }
        isCycling = true
        presentNextCue(entry: .fade)
    }

    private func stopCycle() {
        generation += 1
        isCycling = false
        for label in labels {
            label.layer.removeAllAnimations()
            label.layer.opacity = 0
        }
    }

    private func presentNextCue(entry: CueTransition) {
        guard isActive, !cues.isEmpty else {
            isCycling = false
            return
        }
        let index = nextIndex % cues.count
        let cue = cues[index]
        let exit = transitions.indices.contains(index) ? transitions[index] : .fade
        nextIndex = (index + 1) % cues.count

        // A fade rasterizes the next text on the off-screen label (the
        // double buffer, so drawing never lands mid-fade). A cut stays on
        // the FRONT label: swapping its text while the filled outgoing
        // segment holds opacity 1 is the hard cut — same pill, new line.
        if entry == .fade { frontLabelIndex = 1 - frontLabelIndex }
        let label = labels[frontLabelIndex]
        label.attributedText = Self.renderedCue(cue.text)

        let expected = generation
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in
            guard let self, self.generation == expected else { return }
            self.presentNextCue(entry: exit)
        }
        // The model opacity stays 0 for the whole flight: if the system
        // strips the animations (backgrounding), the labels are invisible —
        // never a frozen mid-fade cue or a stranded pill. Adding on the
        // same key atomically replaces a filled predecessor in this same
        // commit, so a cut never exposes that model value in between.
        label.layer.opacity = 0
        label.layer.add(Self.segmentAnimation(entry: entry, exit: exit), forKey: "subtitle-cue")
        CATransaction.commit()
    }

    /// One cue's opacity envelope, shaped by how it arrives and leaves:
    /// a fade entry opens with the dark beat + fade-in ramp, a cut entry
    /// starts at full opacity instantly; a fade exit closes to 0, a cut
    /// exit ends AT 1 and fills forwards so the pill holds until the
    /// completion swaps in the next cue's text.
    private static func segmentAnimation(entry: CueTransition, exit: CueTransition) -> CAKeyframeAnimation {
        let fade = fadeDuration
        var values: [Float] = []
        var times: [TimeInterval] = []

        switch entry {
        case .fade:
            values += [0, 0, 1]
            times += [0, interCueGap, interCueGap + fade]
        case .cut:
            values += [1]
            times += [0]
        }
        let holdEnd = (times.last ?? 0) + holdDuration
        values.append(1)
        times.append(holdEnd)
        if exit == .fade {
            values.append(0)
            times.append(holdEnd + fade)
        }

        let total = times.last ?? 1
        let animation = CAKeyframeAnimation(keyPath: "opacity")
        animation.values = values
        animation.keyTimes = times.map { NSNumber(value: $0 / total) }
        animation.duration = total
        if exit == .cut {
            // Clamp the final value past the animation's end instead of
            // snapping back to the (invisible) model: the successor replaces
            // this animation in the completion's own transaction.
            animation.fillMode = .forwards
            animation.isRemovedOnCompletion = false
        }
        return animation
    }

    /// One tier below the caption on the chrome's type ladder (caption
    /// body-17 → cue footnote-13 → ticker caption1-12): the size drop is
    /// what keeps the caption dominant. Medium weight holds 13pt text
    /// legible over motion, and the pill supplies the contrast — so no
    /// glyph shadow (a shadow inside a translucent container reads as
    /// smudge, not depth).
    private static func renderedCue(_ text: String) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [
            .font: UIFont.preferredFont(forTextStyle: .footnote).withWeight(.medium),
            .foregroundColor: UIColor.white,
        ])
    }
}

/// A label that bakes the pill's padding into its text rect (rather than
/// wrapping the label in a padded container), so the pill and its glyphs
/// stay one view on one layer — the shape the cue animation depends on.
private final class SubtitlePillLabel: UILabel {
    static let textInsets = UIEdgeInsets(top: 6, left: 12, bottom: 6, right: 12)

    override func textRect(forBounds bounds: CGRect, limitedToNumberOfLines numberOfLines: Int) -> CGRect {
        let textBounds = super.textRect(
            forBounds: bounds.inset(by: Self.textInsets),
            limitedToNumberOfLines: numberOfLines
        )
        return CGRect(
            x: textBounds.minX - Self.textInsets.left,
            y: textBounds.minY - Self.textInsets.top,
            width: textBounds.width + Self.textInsets.left + Self.textInsets.right,
            height: textBounds.height + Self.textInsets.top + Self.textInsets.bottom
        )
    }

    override func drawText(in rect: CGRect) {
        super.drawText(in: rect.inset(by: Self.textInsets))
    }
}
