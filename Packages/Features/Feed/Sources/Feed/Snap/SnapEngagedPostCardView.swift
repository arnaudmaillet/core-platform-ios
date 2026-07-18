import MediaCore
import CoreModels
import DesignSystem
import UIKit

/// The engaged card's content: the post itself, reformatted to fit the top
/// floating glass container. Three bands (`SnapCommentsLayout`'s card
/// constants are the shared geometry contract):
///
///   [avatar  name  @handle · 3m]        — author header
///   [ media hole │ caption column ]     — the media DOCKS here from above
///   [             │ ♫ music line  ]       (a transform-ridden sibling, not
///   [♥ 1.2k  💬 56  ⇄ Repost  🔖 Save]     a subview); the caption is the
///                                          cell's flight label, also above
///   — actions row
///
/// This view deliberately owns NEITHER the media nor the caption: the media
/// is the full-bleed render surface docking via transform (playback
/// untouchable by construction), and the caption is the cell's flight label
/// (it travels from the chrome's full-width home). The card renders
/// everything else — the pieces that have no feed-default counterpart in
/// the cell (author identity lives in the nav bar, music attribution in the
/// native toolbar, metrics nowhere) and therefore ENTER with the card
/// rather than fly.
///
/// Lives inside the strip backdrop's `contentView`, pinned edge-to-edge, so
/// the glass card's frame authority (`stripCardFrame`) is the only geometry
/// it needs — every interior offset is card-local.
final class SnapEngagedPostCardView: UIView {
    private let avatarView = AvatarImageView()
    private let nameLabel = UILabel()
    private let metaLabel = UILabel()

    private let musicRow = UIStackView()
    private let musicLabel = UILabel()

    /// Metrics with data render counts (likes from the hydration snapshot,
    /// comments from the loaded streams); repost/save are affordance-only
    /// seams — the BFF carries no counts for them yet, mirroring the
    /// composer's unwired `onAttachMedia`.
    private let likeButton = SnapEngagedPostCardView.makeMetricButton(
        symbol: "heart", accessibilityLabel: "Like"
    )
    private let commentButton = SnapEngagedPostCardView.makeMetricButton(
        symbol: "bubble.right", accessibilityLabel: "Comments"
    )
    private let repostButton = SnapEngagedPostCardView.makeMetricButton(
        symbol: "arrow.2.squarepath", accessibilityLabel: "Repost"
    )
    private let saveButton = SnapEngagedPostCardView.makeMetricButton(
        symbol: "bookmark", accessibilityLabel: "Save"
    )

    private var representedID: PostID?
    private var avatarTask: Task<Void, Never>?

    override init(frame: CGRect) {
        super.init(frame: frame)
        buildLayout()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func buildLayout() {
        let pad = SnapCommentsLayout.stripCardPadding

        // Author header band: avatar + name + meta on one line, centered in
        // the band. Same type recipe as the identity pill, no shadows — the
        // card's glass provides the contrast the bare bars lack.
        avatarView.backgroundColor = .darkGray
        nameLabel.font = UIFont.preferredFont(forTextStyle: .footnote).withWeight(.semibold)
        nameLabel.textColor = .white
        metaLabel.font = .preferredFont(forTextStyle: .caption2)
        metaLabel.textColor = UIColor.white.withAlphaComponent(0.75)
        metaLabel.setContentCompressionResistancePriority(UILayoutPriority(749), for: .horizontal)

        let headerLabels = UIStackView(arrangedSubviews: [nameLabel, metaLabel])
        headerLabels.axis = .horizontal
        headerLabels.spacing = Spacing.sm
        headerLabels.alignment = .firstBaseline

        avatarView.constrain(in: self) { parent in
            avatarView.leadingAnchor.constraint(equalTo: parent.leadingAnchor, constant: pad)
            avatarView.topAnchor.constraint(
                equalTo: parent.topAnchor,
                constant: pad + (SnapCommentsLayout.cardHeaderHeight - SnapCommentsLayout.cardAvatarDiameter) / 2
            )
            avatarView.widthAnchor.constraint(equalToConstant: SnapCommentsLayout.cardAvatarDiameter)
            avatarView.heightAnchor.constraint(equalToConstant: SnapCommentsLayout.cardAvatarDiameter)
        }
        headerLabels.constrain(in: self) { parent in
            headerLabels.leadingAnchor.constraint(equalTo: avatarView.trailingAnchor, constant: Spacing.sm)
            headerLabels.centerYAnchor.constraint(equalTo: avatarView.centerYAnchor)
            headerLabels.trailingAnchor.constraint(lessThanOrEqualTo: parent.trailingAnchor, constant: -pad)
        }

        // Music line: pinned to the media row's BOTTOM edge in the caption
        // column — the caption (the cell's flight label, above this view)
        // stops above it via `captionColumnMaxY`.
        let musicIcon = UIImageView(image: UIImage(systemName: "music.note")?
            .withConfiguration(UIImage.SymbolConfiguration(pointSize: 11, weight: .semibold)))
        musicIcon.tintColor = UIColor.white.withAlphaComponent(0.75)
        musicIcon.contentMode = .center
        musicLabel.font = .preferredFont(forTextStyle: .caption2)
        musicLabel.textColor = UIColor.white.withAlphaComponent(0.75)
        musicLabel.lineBreakMode = .byTruncatingTail

        musicRow.addArrangedSubview(musicIcon)
        musicRow.addArrangedSubview(musicLabel)
        musicRow.axis = .horizontal
        musicRow.spacing = Spacing.xs
        musicRow.alignment = .center
        musicRow.isHidden = true
        let mediaRowBottom = pad + SnapCommentsLayout.cardHeaderHeight
            + SnapCommentsLayout.cardRowSpacing + SnapCommentsLayout.mediaSlotHeight
        musicRow.constrain(in: self) { parent in
            musicRow.leadingAnchor.constraint(
                equalTo: parent.leadingAnchor,
                constant: pad + SnapCommentsLayout.mediaSlotHeight + Spacing.md
            )
            musicRow.trailingAnchor.constraint(lessThanOrEqualTo: parent.trailingAnchor, constant: -pad)
            musicRow.heightAnchor.constraint(equalToConstant: SnapCommentsLayout.cardMusicLineHeight)
            musicRow.bottomAnchor.constraint(equalTo: parent.topAnchor, constant: mediaRowBottom)
        }

        // Actions band: full card width under the media row.
        let actions = UIStackView(arrangedSubviews: [likeButton, commentButton, repostButton, saveButton])
        actions.axis = .horizontal
        actions.spacing = Spacing.lg
        actions.alignment = .center
        actions.constrain(in: self) { parent in
            actions.leadingAnchor.constraint(equalTo: parent.leadingAnchor, constant: pad)
            actions.trailingAnchor.constraint(lessThanOrEqualTo: parent.trailingAnchor, constant: -pad)
            actions.heightAnchor.constraint(equalToConstant: SnapCommentsLayout.cardActionsHeight)
            actions.bottomAnchor.constraint(equalTo: parent.bottomAnchor, constant: -pad)
        }
    }

    // MARK: - Content

    /// Fills every band from the post's display model. Called at cell
    /// configure — the card is populated long before an engagement, so
    /// engaging is pure choreography, never a data fetch.
    func configure(with model: FeedItemDisplayModel, pipeline: ImagePipeline) {
        representedID = model.id
        nameLabel.text = model.authorName
        metaLabel.text = model.metaText
        // Video posts carry the derived attribution line; other kinds hide
        // the row (the header's meta already covers identity — no fallback
        // duplication).
        musicRow.isHidden = model.audioText == nil
        musicLabel.text = model.audioText
        Self.setCount(model.likeCount > 0 ? Int(clamping: model.likeCount) : nil, on: likeButton)
        Self.setCount(nil, on: commentButton)

        avatarView.image = nil
        avatarTask?.cancel()
        guard let url = model.avatarURL else { return }
        let id = model.id
        avatarTask = Task { [weak self] in
            guard let image = try? await pipeline.image(for: url) else { return }
            guard let self, self.representedID == id else { return }
            self.avatarView.image = image
        }
    }

    /// The comment metric follows the streams (the count the ticker/subtitle
    /// surfaces already receive): shown once loaded, blank while unknown —
    /// the `isLoaded` seam, so a fetch in flight never renders a lying "0".
    func setCommentCount(_ count: Int, isLoaded: Bool) {
        Self.setCount(isLoaded ? count : nil, on: commentButton)
    }

    /// Cell reuse: drop content and cancel the avatar load.
    func reset() {
        representedID = nil
        avatarTask?.cancel()
        avatarTask = nil
        avatarView.image = nil
        nameLabel.text = nil
        metaLabel.text = nil
        musicLabel.text = nil
        musicRow.isHidden = true
        Self.setCount(nil, on: likeButton)
        Self.setCount(nil, on: commentButton)
    }

    // MARK: - Metric buttons

    /// One metric/action: a glyph with an optional count beside it. Buttons
    /// (not labels) so each is a `UIControl` — the cell's tap arbitration
    /// automatically exempts them from the strip's tap-to-close, and the
    /// action seams can wire straight in when the mutation paths exist.
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
