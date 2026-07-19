import CoreModels
import DesignSystem
import UIKit

/// The post-info component of the engaged card: the caption text and the
/// interaction counters, encapsulated as one standalone piece that manages
/// its own internal padding and vertical balance. It fills the glass card's
/// interior and lays out:
///
///   [ (media inset) caption, centered in its band ]
///   [ …                        ♥ 1.2k 💬 56 ⇄ 🔖 ]  ← RIGHT-aligned
///
/// The counters are right-aligned on EVERY post type (the unified rule).
/// The caption centers in the band above them via an internal layout guide,
/// so equal breathing sits above and below the text whatever the line count
/// — no injected margin, no format branch beyond the one leading inset.
///
/// The single composition input is `setHasMedia`: with media the caption
/// starts past the media slot (the `SnapMediaCardView` sits there); text
/// posts omit that component, so the caption claims the card's left inner
/// edge and stretches across the full width. Author identity lives in the
/// nav pill and the audio credit in the toolbar attribution — neither is
/// duplicated here (keep-and-stack).
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
    /// The caption's leading — its constant is the media-slot seam
    /// (`setHasMedia`): past the slot with media, the card's inner padding
    /// without.
    private var captionLeadingConstraint: NSLayoutConstraint?

    /// The caption's leading inset, card-local: past the media slot with
    /// media, the card's own inner padding without (the media component is
    /// omitted, so the caption claims the hole).
    static func captionLeading(hasMedia: Bool) -> CGFloat {
        let pad = SnapCommentsLayout.stripCardPadding
        return hasMedia ? pad + SnapCommentsLayout.mediaSlotHeight + Spacing.md : pad
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        buildLayout()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func buildLayout() {
        let pad = SnapCommentsLayout.stripCardPadding

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
        addSubview(captionLabel)

        // Counters: the column's floor, RIGHT-ALIGNED on every post type.
        let actions = UIStackView(arrangedSubviews: [likeButton, commentButton, repostButton, saveButton])
        actions.axis = .horizontal
        actions.spacing = Spacing.lg
        actions.alignment = .center
        actions.translatesAutoresizingMaskIntoConstraints = false
        addSubview(actions)

        // The caption's band: from the card's top inner padding down to the
        // counters row. The caption CENTERS in it (equal breathing above
        // and below), clamped so a tall caption never crosses either edge.
        let band = UILayoutGuide()
        addLayoutGuide(band)

        let leading = captionLabel.leadingAnchor.constraint(
            equalTo: leadingAnchor, constant: SnapPostInfoCardView.captionLeading(hasMedia: true)
        )
        captionLeadingConstraint = leading
        let centerY = captionLabel.centerYAnchor.constraint(equalTo: band.centerYAnchor)
        centerY.priority = UILayoutPriority(999) // yields to the band clamps on a tall caption

        NSLayoutConstraint.activate([
            actions.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -pad),
            actions.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: pad),
            actions.heightAnchor.constraint(equalToConstant: SnapCommentsLayout.cardActionsHeight),
            actions.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -pad),

            band.topAnchor.constraint(equalTo: topAnchor, constant: pad + Spacing.xs),
            band.bottomAnchor.constraint(equalTo: actions.topAnchor, constant: -Spacing.xs),

            leading,
            captionLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -pad),
            centerY,
            captionLabel.topAnchor.constraint(greaterThanOrEqualTo: band.topAnchor),
            captionLabel.bottomAnchor.constraint(lessThanOrEqualTo: band.bottomAnchor),
        ])
    }

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

    /// The one composition seam: media posts inset the caption past the
    /// media component; text posts (which omit it) claim the full width.
    func setHasMedia(_ hasMedia: Bool) {
        captionLeadingConstraint?.constant = Self.captionLeading(hasMedia: hasMedia)
        setNeedsLayout()
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
