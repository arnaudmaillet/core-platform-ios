import DesignSystem
import UIKit

/// The subtitle zone: semantic comments rendered one at a time, movie-
/// subtitle style — fade in, hold, fade out — directly above the reaction
/// band. The conveyor drifts; this zone breathes.
///
/// # Engine
/// One `CAKeyframeAnimation` on `opacity` per cue (gap → fade-in → hold →
/// fade-out), whose completion advances the wrap-around queue. Deliberately
/// no timers: the band's device triage proved wall-clock cadence desyncs
/// from the layer clock under percent-driven transitions, and a single
/// animation per cue keeps pacing and rendering on the same clock. Steady
/// state costs the compositor one alpha-blended text layer; the main thread
/// is touched once per cue to rasterize the next text (double-buffered
/// labels, off the fade path).
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
    static let fadeDuration: TimeInterval = 0.25
    static let holdDuration: TimeInterval = 3.5
    /// Dark beat between consecutive cues — the subtitle idiom needs a gap
    /// so replacement reads as a new line, not a text mutation. Also the
    /// lead-in delay after activation.
    static let interCueGap: TimeInterval = 0.35

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
    /// Double buffer: the next cue rasterizes on the off-screen label while
    /// the current one holds, so text drawing never lands mid-fade.
    private let labels = [UILabel(), UILabel()]
    private var frontLabelIndex = 0

    override init(frame: CGRect) {
        super.init(frame: frame)
        isHidden = true
        isUserInteractionEnabled = false // taps fall through to play/pause
        for label in labels {
            label.numberOfLines = 2
            label.lineBreakMode = .byTruncatingTail
            label.textAlignment = .center
            label.layer.opacity = 0
            // Bottom-pinned so a one-line cue sits where a two-line cue's
            // last line does — the subtitle baseline never jumps.
            label.constrain(in: self) { parent in
                label.leadingAnchor.constraint(equalTo: parent.leadingAnchor)
                label.trailingAnchor.constraint(equalTo: parent.trailingAnchor)
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
        CGSize(
            width: UIView.noIntrinsicMetric,
            height: ceil(UIFont.preferredFont(forTextStyle: .body).lineHeight * 2)
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
    }

    private func startIfNeeded() {
        guard isActive, !cues.isEmpty, !isCycling else { return }
        isCycling = true
        presentNextCue()
    }

    private func stopCycle() {
        generation += 1
        isCycling = false
        for label in labels {
            label.layer.removeAllAnimations()
            label.layer.opacity = 0
        }
    }

    private func presentNextCue() {
        guard isActive, !cues.isEmpty else {
            isCycling = false
            return
        }
        let cue = cues[nextIndex % cues.count]
        nextIndex = (nextIndex + 1) % cues.count
        frontLabelIndex = 1 - frontLabelIndex
        let label = labels[frontLabelIndex]
        label.attributedText = Self.renderedCue(cue.text)

        let fade = Self.fadeDuration
        let total = Self.interCueGap + fade + Self.holdDuration + fade
        let animation = CAKeyframeAnimation(keyPath: "opacity")
        animation.values = [0, 0, 1, 1, 0]
        animation.keyTimes = [
            0,
            Self.interCueGap / total,
            (Self.interCueGap + fade) / total,
            (Self.interCueGap + fade + Self.holdDuration) / total,
            1,
        ].map { NSNumber(value: $0) }
        animation.duration = total

        let expected = generation
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in
            guard let self, self.generation == expected else { return }
            self.presentNextCue()
        }
        // The model opacity stays 0 for the whole flight: if the system
        // strips the animation (backgrounding), the label is invisible —
        // never a frozen mid-fade cue.
        label.layer.opacity = 0
        label.layer.add(animation, forKey: "subtitle-cue")
        CATransaction.commit()
    }

    /// Same legibility recipe as the chrome's caption: glyph-drawn shadow,
    /// never `layer.shadow*` — a layer shadow on an animating layer is a
    /// per-frame offscreen pass (the band's locked lesson).
    private static func renderedCue(_ text: String) -> NSAttributedString {
        let shadow = NSShadow()
        shadow.shadowColor = UIColor.black.withAlphaComponent(0.5)
        shadow.shadowBlurRadius = 3
        shadow.shadowOffset = .zero
        return NSAttributedString(string: text, attributes: [
            .font: UIFont.preferredFont(forTextStyle: .body),
            .foregroundColor: UIColor.white,
            .shadow: shadow,
        ])
    }
}
