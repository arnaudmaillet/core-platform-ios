import DesignSystem
import UIKit

/// The subtitle zone: semantic comments rendered one at a time, directly
/// above the reaction band — a PERSISTENT subtitle track. The first cue
/// fades in; from then on the pill stays pinned at full opacity and every
/// cue holds until the timeline delivers its successor, which replaces it
/// as an instant text swap on the same pill (a hard cut). Nothing ever
/// fades out into an empty zone mid-watch: the pill leaves the screen only
/// when the page deactivates (swipe away, playback stops) or the cell is
/// recycled.
///
/// # Look
/// A left-aligned translucent pill hugging its text, one typographic tier
/// below the caption (footnote/medium vs the caption's body): the caption is
/// the post's voice and stays dominant; cues stack on the same leading axis
/// as the caption below, one column of text up the page. The pill (not a
/// glyph shadow) carries legibility over bright or moving video.
///
/// Leading the pill sits the count bubble — a material-blur chip with the
/// post's total comment count, the layer's engagement anchor. The row flows
/// `[bubble] [gap] [pill →]`, both bottom-pinned to the zone: a two-line
/// cue grows the pill upward while the bubble holds the shared bottom edge.
/// The bubble fades in once with the first cue and stays clamped visible;
/// handoffs never touch its layer.
///
/// # Engine
/// One `CAKeyframeAnimation` on `opacity` per cue segment, used as the
/// pacing clock — deliberately no timers: the band's device triage proved
/// wall-clock cadence desyncs from the layer clock under percent-driven
/// transitions. Persistence is built from the fill-forwards handoff: every
/// segment ends AT full opacity and is NOT removed on completion, so the
/// pill stays clamped visible while the completion swaps the next cue's
/// text on the same label and replaces the animation on the same key in
/// one transaction. No frame can fall back to the invisible model value —
/// the pill is continuous by construction, and the swap is a single-frame
/// text refresh under a perfectly stable container. Steady state costs the
/// compositor one alpha-blended pill layer; the main thread is touched
/// once per handoff to rasterize the next text.
///
/// # Timing seam
/// Display duration is "until the next cue arrives", never a decay of its
/// own. Cues carry an optional playback-timeline anchor (`SubtitleCue.at`),
/// unused today: v1 paces arrivals evenly (`cueInterval` from activation),
/// which is also the permanent fallback for image posts (no timeline).
/// When the API delivers timestamps, arrivals move onto the player clock;
/// this view keeps rendering "the current cue" either way.
///
/// # Lifecycle
/// Settle-scoped (active), deliberately unlike the band's visibility scope:
/// subtitles belong to the playback timeline, and a page dragged halfway in
/// has no playing media — its zone stays blank until the page settles, the
/// same gate video uses. Hard stop/start with a generation counter (the
/// band's doctrine): deactivation removes animations — filled segments
/// included — and the model opacity parked at 0 means backgrounding (which
/// strips CA animations) hides the zone rather than stranding a pill.
/// Fade-only motion, so the zone stays on under Reduce Motion even while
/// the conveyor hides.
final class SnapSubtitleView: UIView {
    /// The first appearance only — handoffs between cues are hard cuts.
    static let fadeDuration: TimeInterval = 0.10
    /// Dark lead-in between activation and the first cue, so the zone
    /// doesn't pop the instant the page settles.
    static let leadInDelay: TimeInterval = 0.35
    /// v1 even pacing: how often "the next cue arrives" while cues carry no
    /// timeline anchors. This is the successor's arrival cadence, NOT an
    /// expiry — a cue is never taken down, only replaced.
    static let cueInterval: TimeInterval = 3.5

    private var cues: [SubtitleCue] = []
    private var nextIndex = 0
    /// Mirrors the owning cell's settled-active state; content may arrive
    /// before or after it, so both paths funnel into `startIfNeeded`.
    private var isActive = false
    private var isCycling = false
    /// Invalidates stale CA completions across stops — completions fire even
    /// for removed animations, and a stale one must not advance a cycle a
    /// newer owner already reset.
    private var generation = 0
    /// One persistent pill: hard cuts swap text on the visible label, so
    /// there is nothing to double-buffer.
    private let label = SubtitlePillLabel()
    /// The engagement anchor: a material-blur bubble carrying the post's
    /// total comment count, leading the pill. It fades in once with the
    /// first cue and then just sits there — cue handoffs never touch it,
    /// so it can't participate in (or break) the zero-flicker pipeline.
    private let countBubble = UIVisualEffectView(effect: UIBlurEffect(style: .systemThinMaterialDark))
    private let countLabel = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        isHidden = true
        isUserInteractionEnabled = false // taps fall through to play/pause
        label.numberOfLines = 2
        label.lineBreakMode = .byTruncatingTail
        label.textAlignment = .left
        label.layer.opacity = 0
        // The pill lives on the label's own layer so a segment still touches
        // exactly one layer (background and glyphs move as a unit).
        // Deliberately no `masksToBounds`: `backgroundColor` clips to the
        // radius on its own, the text never reaches the corners (it's inset
        // — see `SubtitlePillLabel`), and an unmasked layer keeps the fade
        // a direct composite.
        label.layer.backgroundColor = UIColor.black.withAlphaComponent(0.45).cgColor
        label.layer.cornerRadius = 12 // fixed, so 1- and 2-line cues share one shape
        label.layer.cornerCurve = .continuous
        // The count bubble: a rounded material chip that hugs its count.
        // Blur NEEDS `clipsToBounds` for the rounded shape (unlike the
        // pill's backgroundColor, an effect view's backdrop doesn't clip to
        // the layer radius on its own) — safe here because the bubble's
        // layer never animates after its one fade-in.
        countBubble.clipsToBounds = true
        countBubble.layer.cornerRadius = 12
        countBubble.layer.cornerCurve = .continuous
        countBubble.layer.opacity = 0
        countLabel.font = UIFont.preferredFont(forTextStyle: .footnote).withWeight(.semibold)
        countLabel.textColor = .white
        // The pill's vertical insets on the same footnote tier, so the
        // bubble's height exactly equals a one-line pill — flush top and
        // bottom when the cue is short.
        countLabel.constrain(in: countBubble.contentView) { parent in
            countLabel.leadingAnchor.constraint(equalTo: parent.leadingAnchor, constant: 10)
            countLabel.trailingAnchor.constraint(equalTo: parent.trailingAnchor, constant: -10)
            countLabel.topAnchor.constraint(equalTo: parent.topAnchor, constant: SubtitlePillLabel.textInsets.top)
            countLabel.bottomAnchor.constraint(equalTo: parent.bottomAnchor, constant: -SubtitlePillLabel.textInsets.bottom)
        }

        // Horizontal flow: [count bubble] [gap] [pill →]. Both BOTTOM-pin
        // to the zone, which IS the vertical alignment invariant: a cue
        // wrapping to two lines grows the pill upward while the bubble
        // holds the shared bottom edge — it never centers or rides to the
        // top. The bubble hugs its count; the pill hugs its text and may
        // reclaim all remaining width.
        countBubble.constrain(in: self) { parent in
            countBubble.leadingAnchor.constraint(equalTo: parent.leadingAnchor)
            countBubble.bottomAnchor.constraint(equalTo: parent.bottomAnchor)
        }
        label.constrain(in: self) { parent in
            label.leadingAnchor.constraint(equalTo: countBubble.trailingAnchor, constant: Spacing.sm)
            label.trailingAnchor.constraint(lessThanOrEqualTo: parent.trailingAnchor)
            label.bottomAnchor.constraint(equalTo: parent.bottomAnchor)
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
        nextIndex = 0
        isHidden = newCues.isEmpty
        startIfNeeded()
    }

    /// Updates the count bubble's engagement figure. Rides the same
    /// update path as the cues (`updateCommentStreams`, never `configure`),
    /// so the flight replica's bubble stays empty and invisible by
    /// construction. Text-only (no relayout beyond the bubble's own hug);
    /// visibility is owned by the cue cycle's fade-in.
    func setCommentCount(_ count: Int) {
        countLabel.text = count > 0 ? Self.countText(count) : nil
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
        nextIndex = 0
        isActive = false
        isHidden = true
        countLabel.text = nil
    }

    private func startIfNeeded() {
        guard isActive, !cues.isEmpty, !isCycling else { return }
        isCycling = true
        presentNextCue(fadingIn: true)
    }

    private func stopCycle() {
        generation += 1
        isCycling = false
        label.layer.removeAllAnimations()
        label.layer.opacity = 0
        countBubble.layer.removeAllAnimations()
        countBubble.layer.opacity = 0
    }

    private func presentNextCue(fadingIn: Bool) {
        guard isActive, !cues.isEmpty else {
            isCycling = false
            return
        }
        let index = nextIndex % cues.count
        nextIndex = (index + 1) % cues.count
        // On a handoff (`fadingIn == false`) the predecessor's filled
        // segment is still clamping the pill at full opacity, so setting the
        // text here IS the hard cut — same pill, new line, one frame.
        label.attributedText = Self.renderedCue(cues[index].text)

        let expected = generation
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in
            guard let self, self.generation == expected else { return }
            self.presentNextCue(fadingIn: false)
        }
        // The model opacity stays 0 forever: if the system strips the
        // animations (backgrounding), the label is invisible — never a
        // stranded pill. Adding on the same key atomically replaces the
        // filled predecessor in this same commit, so a handoff never
        // exposes that model value in between.
        label.layer.opacity = 0
        label.layer.add(Self.segmentAnimation(fadingIn: fadingIn), forKey: "subtitle-cue")
        // The count bubble fades in alongside the first cue, then its
        // filled animation clamps it visible for the page's whole active
        // life — handoffs never touch this layer, so the bubble is inert
        // through every hard cut (and backgrounding still hides it, same
        // model-at-0 doctrine).
        if fadingIn, countLabel.text != nil {
            countBubble.layer.opacity = 0
            countBubble.layer.add(Self.bubbleFadeIn(), forKey: "subtitle-count")
        }
        CATransaction.commit()
    }

    /// The bubble's one-shot entrance: the first cue's lead-in + fade
    /// envelope, ending AT 1 and filled forwards indefinitely (its "hold"
    /// is the page's active lifetime; only `stopCycle` takes it down).
    /// Internal (not private) so tests can pin the envelope.
    static func bubbleFadeIn() -> CAKeyframeAnimation {
        let total = leadInDelay + fadeDuration
        let animation = CAKeyframeAnimation(keyPath: "opacity")
        animation.values = [0, 0, 1]
        animation.keyTimes = [0, NSNumber(value: leadInDelay / total), 1]
        animation.duration = total
        animation.fillMode = .forwards
        animation.isRemovedOnCompletion = false
        return animation
    }

    /// Compact engagement figure — the engagement rail's old recipe,
    /// verbatim, so counts read identically wherever they resurface.
    /// Internal (not private) for tests.
    static func countText(_ count: Int) -> String {
        count >= 1000 ? String(format: "%.1fk", Double(count) / 1000) : String(count)
    }

    /// One cue's opacity segment. The first fades in after the lead-in;
    /// every segment — first included — ends AT full opacity and fills
    /// forwards, because a cue's exit does not exist: it is only ever
    /// replaced by its successor (or torn down with the page). The
    /// animation's end is nothing but the successor's arrival clock.
    /// Internal (not private) so tests can pin the envelope shapes.
    static func segmentAnimation(fadingIn: Bool) -> CAKeyframeAnimation {
        let animation = CAKeyframeAnimation(keyPath: "opacity")
        if fadingIn {
            let total = leadInDelay + fadeDuration + cueInterval
            animation.values = [0, 0, 1, 1]
            animation.keyTimes = [
                0,
                leadInDelay / total,
                (leadInDelay + fadeDuration) / total,
                1,
            ].map { NSNumber(value: $0) }
            animation.duration = total
        } else {
            animation.values = [1, 1]
            animation.keyTimes = [0, 1]
            animation.duration = cueInterval
        }
        animation.fillMode = .forwards
        animation.isRemovedOnCompletion = false
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
