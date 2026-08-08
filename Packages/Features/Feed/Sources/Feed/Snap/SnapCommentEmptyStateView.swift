import DesignSystem
import UIKit

/// The comments empty state: a static "No comments yet" pill in the band's
/// slot directly above the caption, shown when a media post HAS NO COMMENTS
/// — the count itself is the whole condition (product decision 2026-08-08).
/// Groundwork for the comment system: when the composer lands, this pill is
/// where the inline "add a comment" invite goes (one `interactionRoots`
/// entry away).
///
/// A post WITH comments never gets a pill, not even when both live surfaces
/// gate themselves away and leave the zone blank: the comment stream is the
/// only thing allowed to speak for a post that has one, and a count standing
/// in for it reads as a substitute for the stream rather than as the stream.
/// (A brief experiment put "2 comments" in that slot; it was removed.)
///
/// Still gated on `CommentStreams.isLoaded`: an unloaded stream carries a
/// zero count too, so without that seam the pill would flash on every page
/// while its fetch is in flight.
///
/// # The label recedes; it never leaves
/// The words hold at full strength for a reading beat, then settle to
/// `labelRestingOpacity` and stay there. Muted, not gone: the page gets its
/// media back, while a viewer arriving late — or glancing down after the
/// beat has passed — is still told why the zone is empty instead of being
/// left a bare glyph to interpret. The row's geometry never changes through
/// any of it, so the whole slot stays one tap into the comments.
///
/// Renders the subtitle zone's pill grammar (`SubtitlePillLabel`, footnote/
/// medium) on the caption's leading axis, so the placeholder reads as the
/// comment system's voice — one typographic tier below the caption, like a
/// cue. Static like the caption (no cycling, no count bubble) — and
/// TAPPABLE: it is the comments engagement's entry point (`onTap`), listed
/// in the chrome's `interactionRoots` so the cell's play/pause arbitration
/// yields to it.
///
/// An overlay in the chrome's one-directional stack: presence or absence
/// never moves the caption or anything else, so the flight replica — which
/// never receives streams — keeps identical geometry by construction.
final class SnapCommentEmptyStateView: UIView {
    /// The placeholder's copy; internal so tests pin it in one place.
    static let promptText = "No comments yet"

    /// Fired on tap — the comments engagement's entry point.
    var onTap: (() -> Void)?

    private let label = SubtitlePillLabel()
    /// The comment glyph's seat — the AVATAR SLOT of the row this stands in
    /// for. Same circle a cue's author gets: same diameter, same fill, same
    /// leading edge, so the empty state and a real comment occupy one
    /// column rather than two nearly-aligned ones.
    private let glyphSlot = UIView()
    private let glyphView = UIImageView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        isHidden = true
        label.numberOfLines = 1

        // THE ROW SHAPE: [avatar slot] [gap] [content], exactly as a cue is
        // built. This used to be one pill with the glyph tucked inside it as
        // a text attachment, which put the WORDS on the caption's leading
        // axis where every comment row puts its AVATAR — the placeholder sat
        // half a slot left of the thing it is a placeholder for.
        //
        // The glyph is the comment system's own face: the avatar's
        // placeholder fill, so the slot reads as an author circle with no
        // author in it.
        glyphSlot.backgroundColor = UIColor.white.withAlphaComponent(0.15)
        glyphSlot.layer.cornerRadius = SnapSubtitleView.avatarDiameter / 2
        glyphSlot.layer.cornerCurve = .continuous
        glyphSlot.clipsToBounds = true
        glyphView.contentMode = .center
        glyphView.tintColor = UIColor.white.withAlphaComponent(0.85)

        for view in [glyphSlot, glyphView, label] {
            view.translatesAutoresizingMaskIntoConstraints = false
        }
        addSubview(glyphSlot)
        addSubview(label)
        glyphSlot.addSubview(glyphView)
        NSLayoutConstraint.activate([
            // The slot owns the leading column and centers on the row, the
            // same relationship the cue's avatar wrapper has to its zone.
            glyphSlot.widthAnchor.constraint(equalToConstant: SnapSubtitleView.avatarDiameter),
            glyphSlot.heightAnchor.constraint(equalToConstant: SnapSubtitleView.avatarDiameter),
            glyphSlot.leadingAnchor.constraint(equalTo: leadingAnchor),
            glyphSlot.centerYAnchor.constraint(equalTo: centerYAnchor),
            glyphSlot.topAnchor.constraint(greaterThanOrEqualTo: topAnchor),
            glyphSlot.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor),
            glyphView.centerXAnchor.constraint(equalTo: glyphSlot.centerXAnchor),
            glyphView.centerYAnchor.constraint(equalTo: glyphSlot.centerYAnchor),
            // The pill is the content slot: sm off the slot's trailing edge
            // (the cue's gap), and the taller of the two, so it sets the
            // row's height.
            label.leadingAnchor.constraint(equalTo: glyphSlot.trailingAnchor, constant: Spacing.sm),
            label.trailingAnchor.constraint(equalTo: trailingAnchor),
            label.topAnchor.constraint(equalTo: topAnchor),
            label.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(handleTap)))
        isAccessibilityElement = true
        accessibilityTraits = .button
        renderPrompt()
        // The glyph's point size is derived from the text style, which no
        // `adjustsFontForContentSizeCategory` tracks — re-resolve on Dynamic
        // Type changes so the slot's mark scales with its label.
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { (self: SnapCommentEmptyStateView, _) in
            self.renderPrompt()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    @objc private func handleTap() {
        onTap?()
    }

    /// Shows/hides the pill and sets its copy for `count`. Idempotent —
    /// cached stream re-emissions arrive on every page activation and must
    /// not restart the entrance. Appearing while on screen (an async load
    /// landing under the user's eyes) announces itself with a short fade,
    /// echoing the other surfaces' content-arrival entrance; off-window (the
    /// dequeue pull) it appears instantly and rides the swipe like static
    /// chrome. Fade-only, so it stays on under Reduce Motion.
    ///
    /// `restingAlpha` is the chrome's current engagement fade (see
    /// `SnapChromeView.setCommentsEngagedProgress`), and it is the opacity
    /// this pill settles at — NOT 1. Alpha is shared state between the
    /// entrance here and that fade, and this surface is the only one that
    /// writes it directly; a stream re-emitting while the comments layout is
    /// open (cached streams re-emit on every page activation) would
    /// otherwise animate the pill back to full opacity on top of it.
    func setVisible(_ visible: Bool, restingAlpha: CGFloat = 1) {
        guard isHidden == visible else { return }
        layer.removeAllAnimations()
        alpha = restingAlpha
        isHidden = !visible
        // The entrance is for content landing under the viewer's eyes on a
        // RESTING page. A faded-out page has no entrance to make.
        if visible, window != nil, restingAlpha > 0 {
            alpha = 0
            UIView.animate(withDuration: 0.2) { self.alpha = restingAlpha }
        }
        applyLabelDwell()
    }

    // MARK: - The label's dwell

    /// How long "No comments yet" is read at full strength before it settles
    /// back, and how long the settling takes. The dwell is a READING beat,
    /// not a transition — it is generous on purpose, and it is measured from
    /// the moment the words are actually in front of someone (see
    /// `setActive`), never from when their stream landed.
    static let labelDwell: TimeInterval = 4.5
    static let labelFadeDuration: TimeInterval = 0.35
    /// Where the words SETTLE — muted, not gone. They recede so the page can
    /// have its media back, and they stay legible so a viewer arriving late
    /// (or glancing back) still gets told why the zone is empty rather than
    /// being left with a bare glyph to interpret. Both the pill's backing
    /// and its text ride this one layer, so the contrast pairing survives
    /// the fade intact — it dims as a unit instead of leaving white text
    /// stranded over bright media.
    static let labelRestingOpacity: Float = 0.45
    private static let dwellKey = "empty-state-label-dwell"

    /// Mirrors the owning page's on-screen state, the same seam the subtitle
    /// zone rides (`SnapChromeView.setSubtitlesActive`). The dwell is a
    /// READING clock, so it must not start on a page nobody is looking at —
    /// armed at the dequeue pull it would burn while the cell is off-screen
    /// and the words would already be gone by the time the page arrives.
    private var isActive = false
    private var hasArmedDwell = false

    func setActive(_ active: Bool) {
        guard active != isActive else { return }
        isActive = active
        applyLabelDwell()
    }

    /// Rewinds the beat and reads the words again from full strength.
    ///
    /// The comments engagement is the caller: coming back out of it is a
    /// RETURN to the page, and the page introduces itself the way it did
    /// the first time. Without this the viewer closes the comments onto a
    /// pre-muted label — the one moment they have most recently expressed
    /// interest in this post's comments is the moment the explanation would
    /// be at its faintest.
    ///
    /// Unconditional restart, not a resume: `cancelLabelDwell` restores full
    /// opacity even when nothing is armed, so a row that never got to speak
    /// (engaged before its beat finished) still gets a whole one.
    func restartLabelDwell() {
        cancelLabelDwell()
        applyLabelDwell()
    }

    private func applyLabelDwell() {
        if isActive, !isHidden {
            armLabelDwell()
        } else {
            cancelLabelDwell()
        }
    }

    /// One fill-forwards keyframe rather than a timer — the band's and the
    /// zone's doctrine, for the same reason: wall-clock cadence desyncs from
    /// the layer clock while a page rides a percent-driven transition, and a
    /// layer animation also stops paying for itself the moment the page
    /// leaves the screen.
    ///
    /// The model value is parked at the RESTING opacity and the animation
    /// HOLDS the label at full strength for the dwell before ramping down
    /// onto it. Ending on the model value is what keeps backgrounding —
    /// which strips CA animations — from snapping the words back to full.
    private func armLabelDwell() {
        guard !hasArmedDwell else { return }
        hasArmedDwell = true
        let total = Self.labelDwell + Self.labelFadeDuration
        let animation = CAKeyframeAnimation(keyPath: "opacity")
        animation.values = [1, 1, Self.labelRestingOpacity]
        animation.keyTimes = [0, NSNumber(value: Self.labelDwell / total), 1]
        animation.duration = total
        animation.fillMode = .forwards
        animation.isRemovedOnCompletion = false
        label.layer.opacity = Self.labelRestingOpacity
        label.layer.add(animation, forKey: Self.dwellKey)
    }

    /// Restores the words to full strength, ready to be read again the next
    /// time this row appears — a page revisited, or the scaffold recycled
    /// onto another zero-comment post.
    private func cancelLabelDwell() {
        hasArmedDwell = false
        label.layer.removeAnimation(forKey: Self.dwellKey)
        label.layer.opacity = 1
    }

    /// One tier below the caption, the cue pill's exact type recipe
    /// (footnote/medium, white on the translucent pill) — and, in the slot
    /// beside it, the comment-bubble mark that says this row speaks for the
    /// comment system rather than for a commenter.
    private func renderPrompt() {
        accessibilityLabel = Self.promptText
        let font = UIFont.preferredFont(forTextStyle: .footnote).withWeight(.medium)
        label.font = font
        label.textColor = .white
        label.text = Self.promptText
        glyphView.image = UIImage(
            systemName: "bubble.left",
            withConfiguration: UIImage.SymbolConfiguration(font: font, scale: .small)
        )
    }
}
