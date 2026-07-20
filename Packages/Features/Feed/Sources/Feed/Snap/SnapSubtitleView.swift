import DesignSystem
import MediaCore
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
/// Visibility-scoped (the band's seam, plus the settle backstop for
/// foregrounding): the persistent pill is static content between handoffs,
/// so a page dragged partway in must show its zone riding the cell like
/// the caption — not pop it in after settle. Entrances split on who moved
/// first: a page that already owns its cues (prefetched at dequeue, or a
/// revisit) presents INSTANTLY; cues that land while the page is already
/// on screen announce themselves with the lead-in + fade. Hard stop/start
/// with a generation counter (the band's doctrine): deactivation removes
/// animations — filled segments included — and the model opacity parked at
/// 0 means backgrounding (which strips CA animations) hides the zone
/// rather than stranding a pill. Fade-only motion, so the zone stays on
/// under Reduce Motion even while the conveyor hides.
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
    /// The author avatar leading the cue — a compact round image at the
    /// zone's leading edge, CENTERED vertically on the pill so it holds the
    /// same middle whether the cue is one line or two, while the text flows
    /// to its right (line two aligns with line one's leading edge, never
    /// wrapping under the circle). It fades in once with the first cue (the
    /// old count bubble's entrance envelope) and stays clamped visible; each
    /// hard-cut handoff swaps in the new author's image, so it rides the cue
    /// cycle rather than the flicker-free pill pipeline (a separate layer, so
    /// it can't disturb it).
    private static let avatarDiameter: CGFloat = 28
    private let avatarView = AvatarImageView()
    /// The pipeline avatars load through, and the in-flight load — cancelled
    /// on each handoff and on teardown so a slow fetch can't paint a stale
    /// author onto the current cue.
    private var imagePipeline: ImagePipeline?
    private var avatarTask: Task<Void, Never>?
    /// The post's total comment count as a micro-badge floating on the
    /// avatar's top-right corner — a subtle pill (dark, hairline-bordered)
    /// carrying the engagement figure without stealing the leading slot or
    /// disturbing the two-line text flow on the right. Like the avatar it
    /// fades in ONCE with the first cue and stays clamped (its opacity is a
    /// separate layer); it's inert through cue handoffs.
    private static let badgeHeight: CGFloat = 16
    private let countBadge = UIView()
    private let countLabel = UILabel()

    /// A tap landed anywhere in the zone (pill, count bubble, or the slack
    /// between them) — the comments engagement's entry point on posts with
    /// semantic cues. The zone's fixed two-line slot doubles as the thumb
    /// target, comfortably larger than the pill alone; the chrome lists the
    /// zone in `interactionRoots` so the cell's play/pause arbitration
    /// yields, and a hidden zone (below the cue gate) receives no touches.
    var onTap: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isHidden = true
        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(handleTap)))
        isAccessibilityElement = true
        accessibilityTraits = .button
        accessibilityLabel = "Comments"
        label.numberOfLines = 2
        label.lineBreakMode = .byTruncatingTail
        label.textAlignment = .left
        // The pill IS the label's own layer (`SubtitlePillLabel` styles it),
        // so a cue segment still touches exactly one layer — background and
        // glyphs move as a unit.
        label.layer.opacity = 0
        // The avatar: a compact round image at the zone's leading edge. A
        // placeholder fill so an unhydrated/loading author still reads as an
        // avatar rather than a hole. Its opacity rides the cue cycle (fades
        // in once, then clamped), so it starts invisible like the pill.
        avatarView.backgroundColor = UIColor.white.withAlphaComponent(0.15)
        avatarView.layer.opacity = 0

        // The count badge: a subtle dark pill, hairline-bordered so it reads
        // as a distinct chip floating over the avatar. Clipped to its own
        // capsule; the label centers with a little horizontal breathing so a
        // one-digit count is a neat circle and larger figures grow to a pill.
        countBadge.backgroundColor = UIColor.black.withAlphaComponent(0.6)
        countBadge.layer.cornerRadius = Self.badgeHeight / 2
        countBadge.layer.cornerCurve = .continuous
        countBadge.layer.borderWidth = 1
        countBadge.layer.borderColor = UIColor.white.withAlphaComponent(0.3).cgColor
        countBadge.clipsToBounds = true
        countBadge.layer.opacity = 0
        countBadge.isHidden = true
        countBadge.accessibilityIdentifier = "subtitle-count-badge"
        countLabel.font = UIFont.preferredFont(forTextStyle: .caption2).withWeight(.semibold)
        countLabel.textColor = .white
        countLabel.textAlignment = .center

        // Horizontal flow: [avatar] [gap] [pill →]. The avatar CENTERS
        // vertically on the pill and the pill TOP-pins, so the block grows
        // DOWNWARD from a fixed top while the avatar holds the pill's middle
        // whatever its line count — and because the pill's leading is the
        // avatar's trailing, line two aligns with line one's leading edge,
        // never wrapping under the circle. The badge floats on the avatar's
        // top-right corner (flush at the corner, ON the avatar — not into the
        // text gap). Every view is added BEFORE the constraints activate:
        // they cross-reference each other (avatar.centerY → label.centerY,
        // label.leading → avatar.trailing, badge → avatar), so none can be
        // fully constrained until they share this ancestor.
        avatarView.translatesAutoresizingMaskIntoConstraints = false
        label.translatesAutoresizingMaskIntoConstraints = false
        countBadge.translatesAutoresizingMaskIntoConstraints = false
        countLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(avatarView)
        addSubview(label)
        addSubview(countBadge) // above the avatar
        countBadge.addSubview(countLabel)
        NSLayoutConstraint.activate([
            avatarView.widthAnchor.constraint(equalToConstant: Self.avatarDiameter),
            avatarView.heightAnchor.constraint(equalToConstant: Self.avatarDiameter),
            avatarView.leadingAnchor.constraint(equalTo: leadingAnchor),
            avatarView.centerYAnchor.constraint(equalTo: label.centerYAnchor),
            label.leadingAnchor.constraint(equalTo: avatarView.trailingAnchor, constant: Spacing.sm),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            label.topAnchor.constraint(equalTo: topAnchor),

            // Badge: capsule of fixed height, min-width == height (a circle
            // for one digit), hugging its count with small side padding.
            countBadge.heightAnchor.constraint(equalToConstant: Self.badgeHeight),
            countBadge.widthAnchor.constraint(greaterThanOrEqualTo: countBadge.heightAnchor),
            countBadge.trailingAnchor.constraint(equalTo: avatarView.trailingAnchor),
            countBadge.topAnchor.constraint(equalTo: avatarView.topAnchor),
            countLabel.leadingAnchor.constraint(equalTo: countBadge.leadingAnchor, constant: 3),
            countLabel.trailingAnchor.constraint(equalTo: countBadge.trailingAnchor, constant: -3),
            countLabel.centerYAnchor.constraint(equalTo: countBadge.centerYAnchor),
        ])
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { (self: SnapSubtitleView, _) in
            self.invalidateIntrinsicContentSize()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    @objc private func handleTap() {
        onTap?()
    }

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
        // Content landing under the user's eyes announces itself with the
        // fade entrance.
        startIfNeeded(fadingIn: true)
    }

    /// The pipeline cue author avatars load through — set at configure,
    /// before any cue arrives (see `SnapChromeView.setImagePipeline`).
    func setImagePipeline(_ pipeline: ImagePipeline) {
        imagePipeline = pipeline
    }

    /// Updates the count badge floating on the avatar's corner. Zero (or an
    /// unloaded stream) hides it — the leading slot now carries the author
    /// avatar, and the badge is engagement metadata riding along on top.
    /// Rides the same update path as the cues (`updateCommentStreams`, never
    /// `configure`), so the flight replica's badge stays empty and invisible.
    func setCommentCount(_ count: Int) {
        countLabel.text = count > 0 ? Self.countText(count) : nil
        countBadge.isHidden = countLabel.text == nil
    }

    /// Follows the owning page's visibility (the band's seam): a page
    /// dragged partway in is already showing its zone — see the class doc.
    func setActive(_ active: Bool) {
        guard active != isActive else { return }
        isActive = active
        if active {
            // A page that already owns its cues (prefetched at dequeue, or
            // a revisit) presents the current cue INSTANTLY: during a swipe
            // the pill is static content riding the cell, like the caption
            // — an entrance fade here would read as the pop-in this seam
            // exists to prevent.
            startIfNeeded(fadingIn: false)
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
        avatarView.image = nil
        countLabel.text = nil
        countBadge.isHidden = true
    }

    private func startIfNeeded(fadingIn: Bool) {
        guard isActive, !cues.isEmpty, !isCycling else { return }
        isCycling = true
        presentNextCue(fadingIn: fadingIn)
    }

    private func stopCycle() {
        generation += 1
        isCycling = false
        avatarTask?.cancel()
        avatarTask = nil
        label.layer.removeAllAnimations()
        label.layer.opacity = 0
        avatarView.layer.removeAllAnimations()
        avatarView.layer.opacity = 0
        countBadge.layer.removeAllAnimations()
        countBadge.layer.opacity = 0
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
        // text here IS the hard cut — same pill, new line, one frame. The
        // avatar's IMAGE swaps to the new cue's author on the same beat.
        label.attributedText = Self.renderedCue(cues[index].text)
        updateAvatar(url: cues[index].avatarURL)

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
        // The avatar rises ONCE, alongside the first cue and with the same
        // entrance kind, then its filled animation clamps it visible for the
        // page's whole visible life. Handoffs swap its image but never touch
        // this OPACITY layer (the key-presence guard makes the entrance
        // idempotent), so it's inert through every hard cut — and
        // backgrounding still hides it (same model-at-0 doctrine as the pill).
        if avatarView.layer.animation(forKey: "subtitle-avatar") == nil {
            avatarView.layer.opacity = 0
            avatarView.layer.add(Self.bubbleEntrance(fadingIn: fadingIn), forKey: "subtitle-avatar")
        }
        // The count badge rises the same once-and-clamp way IF a count
        // exists — inert through handoffs, hidden by backgrounding via its
        // own model-at-0. (Same idempotent, key-guarded entrance the old
        // count bubble used.)
        if countLabel.text != nil, countBadge.layer.animation(forKey: "subtitle-badge") == nil {
            countBadge.layer.opacity = 0
            countBadge.layer.add(Self.bubbleEntrance(fadingIn: fadingIn), forKey: "subtitle-badge")
        }
        CATransaction.commit()
    }

    /// Swaps the avatar to `url`'s author. Clears to the placeholder first so
    /// a handoff never shows the previous author under the new cue, then
    /// loads asynchronously; the in-flight load is cancelled on the next
    /// handoff and on teardown, and the generation/cancellation guards keep
    /// a late fetch from painting a stale author.
    private func updateAvatar(url: URL?) {
        avatarTask?.cancel()
        avatarView.image = nil
        guard let url, let pipeline = imagePipeline else { return }
        let expected = generation
        avatarTask = Task { [weak self] in
            guard let image = try? await pipeline.image(for: url) else { return }
            guard !Task.isCancelled, let self, self.generation == expected else { return }
            self.avatarView.image = image
        }
    }

    /// The bubble's one-shot entrance, matching the first cue's kind:
    /// the lead-in + fade envelope when content announces itself, or an
    /// immediate clamp when the page slides in already owning its cues.
    /// Either way it ends AT 1 and fills forwards indefinitely (its "hold"
    /// is the page's visible lifetime; only `stopCycle` takes it down).
    /// Internal (not private) so tests can pin the envelopes.
    static func bubbleEntrance(fadingIn: Bool) -> CAKeyframeAnimation {
        let animation = CAKeyframeAnimation(keyPath: "opacity")
        if fadingIn {
            let total = leadInDelay + fadeDuration
            animation.values = [0, 0, 1]
            animation.keyTimes = [0, NSNumber(value: leadInDelay / total), 1]
            animation.duration = total
        } else {
            animation.values = [1, 1]
            animation.keyTimes = [0, 1]
            animation.duration = fadeDuration // any span; the fill does the work
        }
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

    /// One cue's opacity segment. `fadingIn` opens with the lead-in + ramp
    /// (content announcing itself); otherwise the segment is a flat clamp
    /// at 1 — the shape shared by hard-cut handoffs and instant entrances
    /// alike. Every segment ends AT full opacity and fills forwards,
    /// because a cue's exit does not exist: it is only ever replaced by
    /// its successor (or torn down with the page). The animation's end is
    /// nothing but the successor's arrival clock.
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
///
/// The pill's whole visual identity lives here (translucent background,
/// fixed continuous-corner radius so 1- and 2-line text shares one shape):
/// the subtitle zone's cue and the comments empty state render the same
/// pill, and keeping the look in the label is what stops them forking.
/// Deliberately no `masksToBounds`: `backgroundColor` clips to the radius
/// on its own, the text never reaches the corners (it's inset), and an
/// unmasked layer keeps the cue fade a direct composite.
final class SubtitlePillLabel: UILabel {
    static let textInsets = UIEdgeInsets(top: 6, left: 12, bottom: 6, right: 12)

    override init(frame: CGRect) {
        super.init(frame: frame)
        layer.backgroundColor = UIColor.black.withAlphaComponent(0.45).cgColor
        layer.cornerRadius = 12
        layer.cornerCurve = .continuous
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

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
