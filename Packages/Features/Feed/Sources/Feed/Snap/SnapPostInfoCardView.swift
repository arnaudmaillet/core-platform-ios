import CoreModels
import DesignSystem
import UIKit

/// The post's caption as a MESSAGE BUBBLE — one Liquid Glass surface
/// (`SnapGlassCardView`) holding the caption over a right-aligned timestamp:
///
///   ┌─────────────────────────────┐
///   │ Weekend build log: rebuilt  │
///   │ the pipeline end to end…    │
///   │                   10 weeks  │  ← timestamp, TRAILING
///   └─────────────────────────────┘
///
/// It is the comment list's FIRST ROW (see `CaptionBubbleCell`), not a
/// floating card the feed cell reserves a region for. That move is why the
/// interaction counters are gone from it: a scrolling row is a message in a
/// thread, and the ♥/💬/⇄/🔖 cluster belonged to a fixed header. Bookmark and
/// share live in the toolbar, which now keeps them onstage through the
/// engagement.
///
/// It SELF-SIZES. Nothing measures its caption from the outside any more —
/// the list cell's Auto Layout does it, which is what retired the line cap,
/// the measured caption height, and the band slack that a fixed rectangle
/// needed. Author identity is the avatar beside it and the nav pill above;
/// the audio credit is the toolbar's attribution item. Nothing duplicated.
final class SnapPostInfoCardView: UIView {
    private let captionLabel = UILabel()
    /// The post's age ("10 weeks"), trailing-aligned under the caption —
    /// the message-bubble convention, where the timestamp settles into the
    /// bubble's bottom-right corner.
    private let timestampLabel = UILabel()
    /// This component's floating glass bubble, filling it.
    private let glass = SnapGlassCardView()
    /// The caption + timestamp, hosted inside the glass and faded as one for
    /// the entrance — SEPARATE from the glass, whose material materializes
    /// via `effect`, never alpha.
    private let content = UIView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        buildLayout()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func buildLayout() {
        // ONE uniform inset on all four edges — the message-bubble measure,
        // so the text sits well clear of the rounded corner on every side.
        // The only interior spacing is the gap down to the timestamp.
        let inset = Self.contentInset

        glass.translatesAutoresizingMaskIntoConstraints = false
        addSubview(glass)
        glass.pin(to: self)
        content.translatesAutoresizingMaskIntoConstraints = false
        glass.contentView.addSubview(content)
        content.pin(to: glass.contentView)

        captionLabel.font = UIFont.preferredFont(forTextStyle: .subheadline)
        captionLabel.adjustsFontForContentSizeCategory = true
        // SEMANTIC, resolving against whatever the bubble inherits — which
        // is dark on a media panel and the device's theme on a text one (see
        // `SnapGlassCardView`). It was hardcoded white while the glass was
        // pinned dark; white text under a glass that can now render bright
        // is the one combination that reliably disappears.
        captionLabel.textColor = .label
        // Natural alignment — the bubble reads as a message, and a message's
        // text starts at the reading edge in both LTR and RTL.
        captionLabel.textAlignment = .natural
        // NO line cap: the bubble grows to its caption, exactly like every
        // other row in the list. A cap existed only to defend a fixed header
        // region's height, and there is no such region now.
        captionLabel.numberOfLines = 0
        // …and NO tail truncation to go with it. `.byTruncatingTail` is
        // UILabel's default even at `numberOfLines = 0`, which makes a short
        // frame silently swallow the rest of the caption — the label reports
        // itself as fitting and the text just ends in an ellipsis. Word
        // wrapping makes the same situation OVERFLOW instead, which is
        // visible, measurable, and what a self-sizing row is supposed to
        // resolve by growing.
        captionLabel.lineBreakMode = .byWordWrapping
        // The caption's height is the bubble's height. Nothing above it in
        // the stream is allowed to negotiate that away — a squeezed label
        // is a swallowed caption, and this bubble has no fixed region to
        // defend any more.
        captionLabel.setContentCompressionResistancePriority(.required, for: .vertical)
        captionLabel.setContentHuggingPriority(.required, for: .vertical)
        captionLabel.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(captionLabel)

        timestampLabel.font = .preferredFont(forTextStyle: .footnote)
        timestampLabel.adjustsFontForContentSizeCategory = true
        // The quietest text on the bubble. `.secondaryLabel` is the semantic
        // equivalent of the 0.7 white it replaces — subordinate to the
        // caption, and legible on a refracting material in either theme
        // (a fixed white alpha could only ever be tuned for one).
        timestampLabel.textColor = .secondaryLabel
        timestampLabel.textAlignment = .right
        timestampLabel.numberOfLines = 1
        timestampLabel.setContentHuggingPriority(.required, for: .vertical)
        timestampLabel.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(timestampLabel)

        // A clean top→bottom chain, all four margins the same inset: caption
        // from the top, timestamp trailing-pinned beneath it, and the
        // content's own bottom closing the bubble — so the whole thing sizes
        // to its text with no fixed heights anywhere.
        NSLayoutConstraint.activate([
            captionLabel.topAnchor.constraint(equalTo: content.topAnchor, constant: inset),
            captionLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: inset),
            captionLabel.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -inset),

            timestampLabel.topAnchor.constraint(
                equalTo: captionLabel.bottomAnchor, constant: Self.captionActionsGap
            ),
            timestampLabel.leadingAnchor.constraint(
                greaterThanOrEqualTo: content.leadingAnchor, constant: inset
            ),
            timestampLabel.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -inset),
            timestampLabel.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -inset),
        ])
    }

    /// Teaches the caption its wrapping width before anything asks how tall
    /// it is.
    ///
    /// A multi-line `UILabel`'s intrinsic height is a function of a width it
    /// does not know: asked in the abstract it answers as ONE long line.
    /// Auto Layout resolves that in a second pass — but a self-sizing cell
    /// measures with `systemLayoutSizeFitting`, and that measurement takes
    /// the first answer. `preferredMaxLayoutWidth` is what makes the first
    /// answer the right one.
    ///
    /// Sourced from this view's own resolved width minus its insets, so the
    /// number lives where the insets do rather than being re-derived by the
    /// cell. The re-run of `super.layoutSubviews()` is the standard idiom:
    /// the new width changes the label's intrinsic height, and the pass that
    /// already ran used the old one. The guard makes the second pass a
    /// no-op, so it cannot recur.
    override func layoutSubviews() {
        super.layoutSubviews()
        let wrapWidth = bounds.width - Self.contentInset * 2
        guard wrapWidth > 0, abs(captionLabel.preferredMaxLayoutWidth - wrapWidth) > 0.5 else { return }
        captionLabel.preferredMaxLayoutWidth = wrapWidth
        super.layoutSubviews()
    }

    // MARK: - Glass + entrance

    /// Materializes (or dissolves) this bubble's glass — window-guarded, via
    /// the effect property. Call inside the engagement's animation block.
    func setGlassActive(_ active: Bool) { glass.setGlassActive(active) }

    /// The content's entrance pose: a pure fade. The bubble scrolls with the
    /// list now, so it no longer carries the engagement's expand — that
    /// belongs to the container (`streamEntranceScale`).
    func setContentEntrance(offstage: Bool) {
        content.alpha = offstage ? 0 : 1
    }

    /// The content's current entrance state — read-only, for the
    /// choreography test.
    var contentAlpha: CGFloat { content.alpha }

    // MARK: - Content

    /// Fills the bubble. Both fields land synchronously; the bubble sizes
    /// itself to them.
    func configure(caption: String?, timestamp: String?) {
        captionLabel.text = caption
        timestampLabel.text = timestamp
    }

    /// Cell reuse: drop content.
    func reset() {
        captionLabel.text = nil
        timestampLabel.text = nil
    }

    // MARK: - Geometry

    /// The uniform inner margin on ALL FOUR edges. Sourced from
    /// `SnapCommentsLayout` so the bubble's interior and the stream's other
    /// geometry use the identical value.
    static var contentInset: CGFloat { SnapCommentsLayout.cardContentInset }
    /// The one interior gap: between the caption and the timestamp.
    static var captionActionsGap: CGFloat { SnapCommentsLayout.captionActionsGap }
}
