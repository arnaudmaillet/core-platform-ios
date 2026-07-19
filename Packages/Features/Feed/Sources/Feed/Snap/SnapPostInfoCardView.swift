import CoreModels
import DesignSystem
import UIKit

/// The post-info component of the engaged card: the caption text and the
/// interaction counters, drawing its OWN independent Liquid Glass card
/// (`SnapGlassCardView`) and managing its own internal padding and vertical
/// balance. It lays out, inside its glass:
///
///   [ caption, centered in its band ]
///   [ …            ♥ 1.2k 💬 56 ⇄ 🔖 ]  ← RIGHT-aligned
///
/// The counters are right-aligned on EVERY post type (the unified rule).
/// The caption centers in the band above them via an internal layout guide,
/// so equal breathing sits above and below the text whatever the line count
/// — no injected margin, no format branch, no media inset (the media is a
/// SEPARATE glass card beside this one).
///
/// Composition is POSITIONAL: the feed sets this card's frame at
/// `infoCardFrame` — beside the media card on media posts, standalone
/// full-width on text posts. The component itself is format-agnostic.
/// Author identity lives in the nav pill and the audio credit in the
/// toolbar attribution — neither is duplicated here (keep-and-stack).
final class SnapPostInfoCardView: UIView {
    private let captionLabel = UILabel()
    /// Metrics with data render counts (likes from the hydration snapshot,
    /// comments from the loaded streams); repost/save are affordance-only
    /// seams — the BFF carries no counts for them yet.
    private let likeButton = SnapPostInfoCardView.makeMetricButton(
        symbol: "heart", accessibilityLabel: "Like"
    )
    private let commentButton = SnapPostInfoCardView.makeMetricButton(
        symbol: "bubble.right", accessibilityLabel: "Comments"
    )
    private let repostButton = SnapPostInfoCardView.makeMetricButton(
        symbol: "arrow.2.squarepath", accessibilityLabel: "Repost"
    )
    private let saveButton = SnapPostInfoCardView.makeMetricButton(
        symbol: "bookmark", accessibilityLabel: "Save"
    )
    /// This component's OWN floating glass card, filling it — so the info
    /// renders as a distinct glass surface, independent of the media card
    /// beside it (or standalone full-width on text posts).
    private let glass = SnapGlassCardView()
    /// The caption + counters, hosted inside the glass and moved as one for
    /// the entrance (alpha + rise) — SEPARATE from the glass, whose blur
    /// materializes via `effect`, never alpha.
    private let content = UIView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        buildLayout()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func buildLayout() {
        let pad = SnapCommentsLayout.stripCardPadding

        glass.translatesAutoresizingMaskIntoConstraints = false
        addSubview(glass)
        glass.pin(to: self)
        content.translatesAutoresizingMaskIntoConstraints = false
        glass.contentView.addSubview(content)
        content.pin(to: glass.contentView)

        captionLabel.font = UIFont.preferredFont(forTextStyle: .subheadline)
        captionLabel.adjustsFontForContentSizeCategory = true
        captionLabel.textColor = .white
        captionLabel.lineBreakMode = .byTruncatingTail
        // The whole-line budget for the band (a height-compressed label
        // center-clips; only the line cap truncates honestly). Fixed from
        // the card geometry — the card's size is constant.
        captionLabel.numberOfLines = SnapCommentsLayout.captionLineCapacity(
            columnHeight: SnapPostInfoCardView.captionBandHeight,
            lineHeight: captionLabel.font.lineHeight
        )
        captionLabel.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(captionLabel)

        // Counters: the column's floor, RIGHT-ALIGNED on every post type.
        let actions = UIStackView(arrangedSubviews: [likeButton, commentButton, repostButton, saveButton])
        actions.axis = .horizontal
        actions.spacing = Spacing.lg
        actions.alignment = .center
        actions.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(actions)

        // The caption's band: from the card's top inner padding down to the
        // counters row. The caption CENTERS in it (equal breathing above
        // and below), clamped so a tall caption never crosses either edge.
        // The caption always starts at the card's inner padding — the media
        // (when present) is a SEPARATE card, not a hole in this one.
        let band = UILayoutGuide()
        content.addLayoutGuide(band)

        let centerY = captionLabel.centerYAnchor.constraint(equalTo: band.centerYAnchor)
        centerY.priority = UILayoutPriority(999) // yields to the band clamps on a tall caption

        NSLayoutConstraint.activate([
            actions.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -pad),
            actions.leadingAnchor.constraint(greaterThanOrEqualTo: content.leadingAnchor, constant: pad),
            actions.heightAnchor.constraint(equalToConstant: SnapCommentsLayout.cardActionsHeight),
            actions.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -pad),

            band.topAnchor.constraint(equalTo: content.topAnchor, constant: pad + Spacing.xs),
            band.bottomAnchor.constraint(equalTo: actions.topAnchor, constant: -Spacing.xs),

            captionLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: pad),
            captionLabel.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -pad),
            centerY,
            captionLabel.topAnchor.constraint(greaterThanOrEqualTo: band.topAnchor),
            captionLabel.bottomAnchor.constraint(lessThanOrEqualTo: band.bottomAnchor),
        ])
    }

    // MARK: - Glass + entrance

    /// Materializes (or dissolves) this card's glass — window-guarded, via
    /// the effect property. Call inside the engagement's animation block.
    func setGlassActive(_ active: Bool) { glass.setGlassActive(active) }

    /// The content's entrance pose: offstage = invisible with a slight
    /// downward offset (the disengage/rest pose), onstage = risen into
    /// place. The glass frame itself never moves — only its content.
    func setContentEntrance(offstage: Bool) {
        content.alpha = offstage ? 0 : 1
        content.transform = offstage
            ? CGAffineTransform(translationX: 0, y: SnapCommentsLayout.cardContentEntranceOffset)
            : .identity
    }

    /// The content's current entrance state (the glass frame never moves) —
    /// read-only, for the choreography test.
    var contentAlpha: CGFloat { content.alpha }
    var contentEntranceOffset: CGFloat { content.transform.ty }

    // MARK: - Content

    /// Sets the caption text; the layout's line cap and centering are fixed
    /// by the card geometry, so this is content only, never a re-layout.
    func setCaption(_ text: String?) { captionLabel.text = text }

    /// Fills the counters from the post's display model. Called at cell
    /// configure — the card is populated long before an engagement.
    func configure(with model: FeedItemDisplayModel) {
        Self.setCount(model.likeCount > 0 ? Int(clamping: model.likeCount) : nil, on: likeButton)
        Self.setCount(nil, on: commentButton)
    }

    /// The comment metric follows the streams: shown once loaded, blank
    /// while unknown (the `isLoaded` seam — no lying "0" mid-fetch).
    func setCommentCount(_ count: Int, isLoaded: Bool) {
        Self.setCount(isLoaded ? count : nil, on: commentButton)
    }

    /// Cell reuse: drop content.
    func reset() {
        captionLabel.text = nil
        Self.setCount(nil, on: likeButton)
        Self.setCount(nil, on: commentButton)
    }

    // MARK: - Geometry

    /// The caption band's height, card-local: the card interior minus the
    /// counters row and the two `xs` breathing gaps — a pure function of
    /// the shared card geometry.
    private static var captionBandHeight: CGFloat {
        SnapCommentsLayout.cardHeight
            - 2 * SnapCommentsLayout.stripCardPadding
            - SnapCommentsLayout.cardActionsHeight
            - 2 * Spacing.xs
    }

    // MARK: - Metric buttons

    /// One metric/action: a glyph with an optional count beside it. Buttons
    /// (not labels) so each is a `UIControl` — the cell's tap arbitration
    /// automatically exempts them from the strip's tap-to-close.
    private static func makeMetricButton(symbol: String, accessibilityLabel: String) -> UIButton {
        var config = UIButton.Configuration.plain()
        config.image = UIImage(systemName: symbol)?
            .withConfiguration(UIImage.SymbolConfiguration(pointSize: 14, weight: .semibold))
        config.baseForegroundColor = UIColor.white.withAlphaComponent(0.9)
        config.imagePadding = Spacing.xs
        config.contentInsets = .zero
        let button = UIButton(configuration: config)
        button.accessibilityLabel = accessibilityLabel
        button.setContentHuggingPriority(.required, for: .horizontal)
        return button
    }

    private static func setCount(_ count: Int?, on button: UIButton) {
        var config = button.configuration
        config?.attributedTitle = count.map {
            var title = AttributedString(SnapSubtitleView.countText($0))
            title.font = UIFont.preferredFont(forTextStyle: .footnote).withWeight(.semibold)
            return title
        }
        button.configuration = config
    }
}
