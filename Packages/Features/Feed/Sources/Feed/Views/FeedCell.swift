import CoreMedia
import CoreModels
import UIKit

/// Hot-path cell: manual frame layout in `layoutSubviews` mirroring
/// `FeedDisplayModelBuilder`'s math — no Auto Layout, no self-sizing.
/// Images arrive through the pipeline; a stale async result for a reused
/// cell is discarded by comparing `representedID`.
final class FeedCell: UICollectionViewCell {
    static let reuseIdentifier = "FeedCell"

    private let avatarView = UIImageView()
    private let nameLabel = UILabel()
    private let metaLabel = UILabel()
    private let captionLabel = UILabel()
    private let mediaView = UIImageView()
    private let likeButton = UIButton(configuration: .plain())
    private let likeCountLabel = UILabel()

    /// Set by the view controller; called on tap with the represented post.
    var onLikeTapped: ((PostID) -> Void)?
    /// Called when the author's avatar or name is tapped.
    var onAuthorTapped: ((ProfileID) -> Void)?

    private var model: FeedItemDisplayModel?
    private var representedID: PostID?
    private var authorID: ProfileID?
    private var imageTasks: [Task<Void, Never>] = []

    override init(frame: CGRect) {
        super.init(frame: frame)
        contentView.backgroundColor = .systemBackground

        avatarView.clipsToBounds = true
        avatarView.layer.cornerRadius = FeedCellMetrics.avatarSize / 2
        avatarView.backgroundColor = .tertiarySystemFill
        avatarView.contentMode = .scaleAspectFill

        nameLabel.font = FeedCellMetrics.nameFont
        nameLabel.textColor = .label
        metaLabel.font = FeedCellMetrics.metaFont
        metaLabel.textColor = .secondaryLabel

        // The avatar and name route to the author's profile.
        for view in [avatarView, nameLabel] {
            view.isUserInteractionEnabled = true
            view.addGestureRecognizer(UITapGestureRecognizer(
                target: self, action: #selector(authorTapped)
            ))
        }

        captionLabel.numberOfLines = 0

        mediaView.clipsToBounds = true
        mediaView.layer.cornerRadius = FeedCellMetrics.mediaCornerRadius
        mediaView.backgroundColor = .tertiarySystemFill
        mediaView.contentMode = .scaleAspectFill

        var likeConfig = UIButton.Configuration.plain()
        likeConfig.image = UIImage(systemName: "heart")
        likeConfig.contentInsets = .zero
        likeButton.configuration = likeConfig
        likeButton.addAction(UIAction { [weak self] _ in
            guard let id = self?.representedID else { return }
            self?.onLikeTapped?(id)
        }, for: .primaryActionTriggered)

        likeCountLabel.font = FeedCellMetrics.metaFont
        likeCountLabel.textColor = .secondaryLabel

        for view in [avatarView, nameLabel, metaLabel, captionLabel, mediaView, likeButton, likeCountLabel] {
            contentView.addSubview(view)
        }
    }

    /// Updates only the engagement bar — called for live counter ticks and
    /// optimistic like toggles. Never triggers relayout (footer is fixed-height).
    func updateEngagement(_ state: FeedViewModel.EngagementState) {
        likeCountLabel.text = Self.countText(state.likeCount)
        var config = likeButton.configuration
        config?.image = UIImage(systemName: state.isLiked ? "heart.fill" : "heart")
        config?.baseForegroundColor = state.isLiked ? .systemRed : .secondaryLabel
        likeButton.configuration = config
    }

    @objc private func authorTapped() {
        guard let authorID else { return }
        onAuthorTapped?(authorID)
    }

    private static func countText(_ count: Int64) -> String {
        count >= 1000 ? String(format: "%.1fk", Double(count) / 1000) : String(count)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func configure(with model: FeedItemDisplayModel, engagement: FeedViewModel.EngagementState, pipeline: ImagePipeline) {
        self.model = model
        representedID = model.id
        authorID = model.authorID
        updateEngagement(engagement)

        nameLabel.text = model.authorName
        metaLabel.text = model.metaText
        captionLabel.attributedText = model.caption?.attributed
        captionLabel.isHidden = model.caption == nil
        mediaView.isHidden = model.mediaURL == nil
        avatarView.image = nil
        mediaView.image = nil

        loadImage(model.avatarURL, into: avatarView, pipeline: pipeline, expecting: model.id)
        loadImage(model.mediaURL, into: mediaView, pipeline: pipeline, expecting: model.id)
        setNeedsLayout()
    }

    private func loadImage(_ url: URL?, into imageView: UIImageView, pipeline: ImagePipeline, expecting id: PostID) {
        guard let url else { return }
        imageTasks.append(Task { [weak self, weak imageView] in
            guard let image = try? await pipeline.image(for: url) else { return }
            guard let self, self.representedID == id else { return }
            imageView?.image = image
        })
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        representedID = nil
        authorID = nil
        for task in imageTasks {
            task.cancel()
        }
        imageTasks.removeAll()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard let model else { return }

        let margin = FeedCellMetrics.horizontalMargin
        let contentWidth = FeedCellMetrics.contentWidth(cellWidth: bounds.width)
        var y = FeedCellMetrics.verticalPadding

        let avatarSize = FeedCellMetrics.avatarSize
        avatarView.frame = CGRect(x: margin, y: y, width: avatarSize, height: avatarSize)

        let textX = margin + avatarSize + FeedCellMetrics.headerToCaptionSpacing
        let textWidth = bounds.width - textX - margin
        let nameHeight = FeedCellMetrics.nameFont.lineHeight.rounded(.up)
        let metaHeight = FeedCellMetrics.metaFont.lineHeight.rounded(.up)
        let headerTextTop = y + (avatarSize - nameHeight - metaHeight) / 2
        nameLabel.frame = CGRect(x: textX, y: headerTextTop, width: textWidth, height: nameHeight)
        metaLabel.frame = CGRect(x: textX, y: headerTextTop + nameHeight, width: textWidth, height: metaHeight)
        y += avatarSize

        if model.captionHeight > 0 {
            y += FeedCellMetrics.headerToCaptionSpacing
            captionLabel.frame = CGRect(x: margin, y: y, width: contentWidth, height: model.captionHeight)
            y += model.captionHeight
        }

        if model.mediaHeight > 0 {
            y += FeedCellMetrics.captionToMediaSpacing
            mediaView.frame = CGRect(x: margin, y: y, width: contentWidth, height: model.mediaHeight)
            y += model.mediaHeight
        }

        let footerY = y
        let buttonSize: CGFloat = FeedCellMetrics.footerHeight
        likeButton.frame = CGRect(x: margin - 8, y: footerY, width: buttonSize, height: buttonSize)
        let countHeight = FeedCellMetrics.metaFont.lineHeight.rounded(.up)
        likeCountLabel.frame = CGRect(
            x: likeButton.frame.maxX + 2,
            y: footerY + (buttonSize - countHeight) / 2,
            width: contentWidth - buttonSize,
            height: countHeight
        )
    }
}
