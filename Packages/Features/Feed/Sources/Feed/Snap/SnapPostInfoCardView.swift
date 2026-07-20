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
    /// The post's age ("5d") — leading on the actions row, opposite the
    /// counters. Secondary metadata styling (the comment-row timestamp
    /// register). Yields FIRST when the row is tight (truncates), so it can
    /// never push or overlap the counters.
    private let timestampLabel = UILabel()
    /// The counters cluster — stored so its intrinsic width feeds the card's
    /// dynamic-width floor (the card never shrinks below the bottom row).
    private lazy var actionsStack = UIStackView(
        arrangedSubviews: [likeButton, commentButton, repostButton, saveButton]
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
        // ONE uniform inset on all four edges — the caption and the
        // counters are insulated from the hairline border by the same
        // margin top, bottom, leading, and trailing, so the card reads
        // homogeneously balanced whether it's full-width (text) or
        // side-by-side (media). The only interior spacing is the small gap
        // between the caption band and the counters row.
        let inset = Self.contentInset

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
        // The whole-line budget: everything between the top inset and the
        // counters row, in whole lines — the line cap truncates honestly
        // when the caption would exceed it.
        captionLabel.numberOfLines = SnapCommentsLayout.captionLineCapacity(
            columnHeight: SnapPostInfoCardView.captionBandHeight,
            lineHeight: captionLabel.font.lineHeight
        )
        // The caption hugs its text and top-aligns — no vertical
        // centering, so the text starts flush at the top inset with no
        // artificial gap above it.
        captionLabel.setContentHuggingPriority(.required, for: .vertical)
        captionLabel.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(captionLabel)

        // Counters: the column's floor, RIGHT-ALIGNED on every post type.
        let actions = actionsStack
        actions.axis = .horizontal
        actions.spacing = Spacing.lg
        actions.alignment = .center
        actions.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(actions)

        // The timestamp: secondary metadata, leading on the actions row.
        timestampLabel.font = .preferredFont(forTextStyle: .footnote)
        timestampLabel.adjustsFontForContentSizeCategory = true
        timestampLabel.textColor = UIColor.white.withAlphaComponent(0.55)
        timestampLabel.numberOfLines = 1
        timestampLabel.lineBreakMode = .byTruncatingTail
        timestampLabel.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(timestampLabel)

        // COUNTERS WIN: they never compress or move — required hugging AND
        // compression resistance on the stack AND its buttons keep the
        // cluster at its intrinsic width, trailing-pinned. The timestamp
        // HUGS its text tightly (required hugging — it never expands to
        // push the counters) but yields under pressure (required
        // compression resistance dropped to the floor — a tight row
        // truncates the date tail). The gap between them is the flex space.
        actions.setContentHuggingPriority(.required, for: .horizontal)
        actions.setContentCompressionResistancePriority(.required, for: .horizontal)
        for button in [likeButton, commentButton, repostButton, saveButton] {
            button.setContentCompressionResistancePriority(.required, for: .horizontal)
        }
        timestampLabel.setContentHuggingPriority(.required, for: .horizontal)
        timestampLabel.setContentCompressionResistancePriority(UILayoutPriority(1), for: .horizontal)

        // A clean linear top→bottom chain (no centering guide, no midpoint
        // math): the caption pins to the TOP inset, the counters pin to the
        // BOTTOM inset (the card's floor), and the counters clear the
        // caption by the tight `captionActionsGap`. All four edge margins
        // are the same uniform inset. The timestamp shares the counters'
        // baseline row, anchored to the leading edge.
        NSLayoutConstraint.activate([
            captionLabel.topAnchor.constraint(equalTo: content.topAnchor, constant: inset),
            captionLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: inset),
            captionLabel.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -inset),

            actions.topAnchor.constraint(greaterThanOrEqualTo: captionLabel.bottomAnchor, constant: Self.captionActionsGap),
            actions.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -inset),
            actions.heightAnchor.constraint(equalToConstant: SnapCommentsLayout.cardActionsHeight),
            actions.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -inset),

            timestampLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: inset),
            timestampLabel.centerYAnchor.constraint(equalTo: actions.centerYAnchor),
            // Never encroach on the counters — the min flex gap is the
            // truncation boundary (required, so the date clips to fit).
            timestampLabel.trailingAnchor.constraint(lessThanOrEqualTo: actions.leadingAnchor, constant: -Spacing.md),
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

    /// Sets the caption text. The card's DYNAMIC width follows the caption
    /// (a short caption yields a narrow card), so a change re-derives the
    /// intrinsic width.
    func setCaption(_ text: String?) {
        captionLabel.text = text
        invalidateIntrinsicContentSize()
    }

    /// Fills the counters and the timestamp from the post's display model.
    /// Called at cell configure — the card is populated long before an
    /// engagement.
    func configure(with model: FeedItemDisplayModel) {
        Self.setCount(model.likeCount > 0 ? Int(clamping: model.likeCount) : nil, on: likeButton)
        Self.setCount(nil, on: commentButton)
        timestampLabel.text = model.timestampText
        invalidateIntrinsicContentSize()
    }

    /// The comment metric follows the streams: shown once loaded, blank
    /// while unknown (the `isLoaded` seam — no lying "0" mid-fetch). The
    /// count widens the counters, so the card's minimum-width floor follows.
    func setCommentCount(_ count: Int, isLoaded: Bool) {
        Self.setCount(isLoaded ? count : nil, on: commentButton)
        invalidateIntrinsicContentSize()
    }

    /// Cell reuse: drop content.
    func reset() {
        captionLabel.text = nil
        timestampLabel.text = nil
        Self.setCount(nil, on: likeButton)
        Self.setCount(nil, on: commentButton)
        invalidateIntrinsicContentSize()
    }

    // MARK: - Dynamic width

    /// The card sizes its WIDTH to its content: the caption's single-line
    /// width (the caption wraps only when the cell caps it at the region
    /// width), floored at `minimumWidth` so the bottom row never clips. The
    /// height stays layout-driven (the cell pins it to `cardHeight`). The
    /// cell clamps this to the available region and positions it (centered
    /// for text, leading-pinned for media).
    override var intrinsicContentSize: CGSize {
        CGSize(width: max(minimumWidth, captionPreferredWidth), height: UIView.noIntrinsicMetric)
    }

    /// The strict minimum width: the bottom row — the date, the `md` flex
    /// gap, and the counters cluster — plus the two edge insets. Below this
    /// the date or the interaction buttons would clip, so the card never
    /// shrinks past it.
    var minimumWidth: CGFloat {
        let counters = actionsStack.systemLayoutSizeFitting(UIView.layoutFittingCompressedSize).width
        let date = timestampLabel.intrinsicContentSize.width
        return 2 * Self.contentInset + ceil(date) + Spacing.md + ceil(counters)
    }

    /// The width the caption wants on a single line, plus the two insets —
    /// the card's content-driven upper reach before the cell's region clamp
    /// forces it to wrap. Internal: the cell also uses it to decide whether
    /// the caption is single-line (→ the compact card height).
    var captionPreferredWidth: CGFloat {
        guard let text = captionLabel.text, !text.isEmpty, let font = captionLabel.font else {
            return 2 * Self.contentInset
        }
        let width = (text as NSString).size(withAttributes: [.font: font]).width
        return 2 * Self.contentInset + ceil(width)
    }

    /// Caps the caption at the state's line count — ONE line on a compact
    /// (single-line) card, the full band's capacity otherwise. The card
    /// height (cell-set) matches, so the caption fills it with no slack.
    func setCompact(_ compact: Bool) {
        captionLabel.numberOfLines = compact ? 1 : SnapCommentsLayout.captionLineCapacity(
            columnHeight: Self.captionBandHeight, lineHeight: captionLabel.font.lineHeight
        )
    }

    // MARK: - Geometry

    /// The uniform inner margin on ALL FOUR edges — homogeneous top, bottom,
    /// leading, trailing. Sourced from `SnapCommentsLayout` so the compact
    /// card height (which the strip geometry derives) and this interior use
    /// the identical value.
    static var contentInset: CGFloat { SnapCommentsLayout.cardContentInset }
    /// The one interior gap: between the caption band and the counters row
    /// (an internal separation, not an edge margin). Shared with the layout.
    static var captionActionsGap: CGFloat { SnapCommentsLayout.captionActionsGap }

    /// The caption's available height, card-local: the card interior
    /// (minus the two edge insets) minus the counters row and the one
    /// interior gap — the line-cap budget, a pure function of the shared
    /// card geometry and the uniform inset. The caption top-pins into the
    /// TOP of this space (no centering).
    private static var captionBandHeight: CGFloat {
        SnapCommentsLayout.cardHeight
            - 2 * contentInset
            - SnapCommentsLayout.cardActionsHeight
            - captionActionsGap
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
