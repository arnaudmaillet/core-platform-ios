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

    override init(frame: CGRect) {
        super.init(frame: frame)
        isHidden = true
        label.numberOfLines = 1
        label.pin(to: self)
        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(handleTap)))
        isAccessibilityElement = true
        accessibilityTraits = .button
        renderPrompt()
        // The font is baked into the attributed string (the glyph rides as a
        // text attachment), which `adjustsFontForContentSizeCategory` cannot
        // track — re-resolve on Dynamic Type changes.
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
    }

    /// One tier below the caption, the cue pill's exact type recipe
    /// (footnote/medium, white on the translucent pill) with a small
    /// comment-bubble glyph leading the line — the mark that this pill
    /// speaks for the comment system, not for a commenter.
    private func renderPrompt() {
        accessibilityLabel = Self.promptText
        let font = UIFont.preferredFont(forTextStyle: .footnote).withWeight(.medium)
        let text = NSMutableAttributedString()
        if let glyph = UIImage(
            systemName: "bubble.left",
            withConfiguration: UIImage.SymbolConfiguration(font: font, scale: .small)
        )?.withTintColor(UIColor.white.withAlphaComponent(0.85), renderingMode: .alwaysOriginal) {
            text.append(NSAttributedString(attachment: NSTextAttachment(image: glyph)))
            text.append(NSAttributedString(string: "  "))
        }
        text.append(NSAttributedString(string: Self.promptText))
        text.addAttributes(
            [.font: font, .foregroundColor: UIColor.white],
            range: NSRange(location: 0, length: text.length)
        )
        label.attributedText = text
    }
}
