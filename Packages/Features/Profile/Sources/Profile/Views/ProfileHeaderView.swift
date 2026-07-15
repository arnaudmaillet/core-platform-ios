import MediaCore
import DesignSystem
import UIKit

/// The profile identity block, laid out like a classic Instagram header:
/// avatar on the left with the Posts/Followers/Following strip beside it,
/// then name + verified badge, bio, website link, and an edge-to-edge action
/// row (Edit Profile alone, or Follow + Message split half-and-half).
/// Pure presentation — it is handed a finished `ProfileDisplayModel` and an
/// `ImagePipeline`; it owns no data.
final class ProfileHeaderView: UIView {
    private enum Metrics {
        static let avatarSize: CGFloat = 86
        static let badgeSize: CGFloat = 18
    }

    private let avatarView = UIImageView()
    private let monogramLabel = UILabel()
    private let nameLabel = UILabel()
    private let verifiedBadge = UIImageView(image: UIImage(systemName: "checkmark.seal.fill"))
    private let bioLabel = UILabel()
    private let websiteButton = UIButton(configuration: .plain())
    private let postsStat = ProfileStatView(caption: "Posts")
    private let followersStat = ProfileStatView(caption: "Followers")
    private let followingStat = ProfileStatView(caption: "Following")
    private let actionButton = UIButton(configuration: .filled())
    private let messageButton = UIButton(configuration: .gray())

    /// Invoked when the Follow / Following / Edit Profile button is tapped.
    var onActionTapped: (() -> Void)?
    /// Invoked when the Message button is tapped (other users only).
    var onMessageTapped: (() -> Void)?
    /// Invoked with the profile's website URL when the link row is tapped.
    var onWebsiteTapped: ((URL) -> Void)?

    private let imagePipeline: ImagePipeline
    private var avatarTask: Task<Void, Never>?
    private var currentAvatarURL: URL?
    private var websiteURL: URL?

    init(imagePipeline: ImagePipeline) {
        self.imagePipeline = imagePipeline
        super.init(frame: .zero)
        configureSubviews()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    deinit {
        avatarTask?.cancel()
    }

    // MARK: - Configuration

    func configure(with model: ProfileDisplayModel) {
        monogramLabel.text = model.avatarMonogram
        nameLabel.text = model.displayName
        verifiedBadge.isHidden = !model.isVerified

        bioLabel.text = model.bio
        bioLabel.isHidden = !model.hasBio

        websiteURL = model.websiteURL
        websiteButton.configuration?.title = model.websiteText
        websiteButton.isHidden = model.websiteText == nil

        postsStat.setValue(model.postsText)
        followersStat.setValue(model.followerText)
        followingStat.setValue(model.followingText)

        loadAvatar(model.avatarURL)
    }

    /// Styles the action row per the viewer's relationship. The viewer's own
    /// profile gets a lone full-width "Edit Profile"; another user's profile
    /// splits the row between Follow/Following and Message. `.follow` is the
    /// one prominent (filled) call to action.
    func configureAction(_ state: ProfileViewModel.FollowButton) {
        switch state {
        case .hidden:
            actionButton.isHidden = true
            messageButton.isHidden = true
        case .follow:
            actionButton.isHidden = false
            messageButton.isHidden = false
            applyActionStyle(title: "Follow", prominent: true)
        case .following:
            actionButton.isHidden = false
            messageButton.isHidden = false
            applyActionStyle(title: "Following", prominent: false)
        case .edit:
            actionButton.isHidden = false
            messageButton.isHidden = true
            applyActionStyle(title: "Edit Profile", prominent: false)
        }
    }

    private func applyActionStyle(title: String, prominent: Bool) {
        var config: UIButton.Configuration = prominent ? .filled() : .gray()
        config.title = title
        if prominent {
            config.baseBackgroundColor = .systemBlue
            config.baseForegroundColor = .white
        }
        actionButton.configuration = Self.styledAction(config)
    }

    /// Shared chrome for the action row: squared-off Instagram-style buttons
    /// (rounded rect, not capsule) with a semibold compact title.
    private static func styledAction(_ base: UIButton.Configuration) -> UIButton.Configuration {
        var config = base
        config.cornerStyle = .medium
        config.contentInsets = NSDirectionalEdgeInsets(
            top: Spacing.sm, leading: Spacing.sm, bottom: Spacing.sm, trailing: Spacing.sm
        )
        config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
            var attributes = attributes
            attributes.font = UIFont.preferredFont(forTextStyle: .subheadline).withWeight(.semibold)
            return attributes
        }
        return config
    }

    private func loadAvatar(_ url: URL?) {
        guard url != currentAvatarURL || avatarView.image == nil else { return }
        currentAvatarURL = url
        avatarTask?.cancel()
        avatarView.image = nil // fall back to the monogram until (and unless) the image resolves

        guard let url else { return }
        let pipeline = imagePipeline
        avatarTask = Task { [weak self] in
            guard let image = try? await pipeline.image(for: url) else { return }
            guard !Task.isCancelled, self?.currentAvatarURL == url else { return }
            self?.avatarView.image = image
        }
    }

    // MARK: - Layout

    private func configureSubviews() {
        // Avatar: a filled circle with a monogram, overlaid by the image once loaded.
        avatarView.backgroundColor = .tertiarySystemFill
        avatarView.contentMode = .scaleAspectFill
        avatarView.clipsToBounds = true
        avatarView.layer.cornerRadius = Metrics.avatarSize / 2

        monogramLabel.font = .systemFont(ofSize: 34, weight: .semibold)
        monogramLabel.textColor = .secondaryLabel
        monogramLabel.textAlignment = .center
        monogramLabel.pin(to: avatarView)

        // Top row: avatar on the left, counters filling the remaining width.
        let statsRow = UIStackView(arrangedSubviews: [postsStat, followersStat, followingStat])
        statsRow.axis = .horizontal
        statsRow.alignment = .center
        statsRow.distribution = .fillEqually

        let topRow = UIStackView(arrangedSubviews: [avatarView, statsRow])
        topRow.axis = .horizontal
        topRow.alignment = .center
        topRow.spacing = Spacing.lg

        nameLabel.font = UIFont.preferredFont(forTextStyle: .subheadline).withWeight(.semibold)
        nameLabel.adjustsFontForContentSizeCategory = true
        nameLabel.textColor = .label
        nameLabel.numberOfLines = 1

        verifiedBadge.tintColor = .systemBlue
        verifiedBadge.contentMode = .scaleAspectFit
        verifiedBadge.setContentHuggingPriority(.required, for: .horizontal)

        bioLabel.font = .preferredFont(forTextStyle: .subheadline)
        bioLabel.adjustsFontForContentSizeCategory = true
        bioLabel.textColor = .label
        bioLabel.numberOfLines = 0

        // Name + verified badge sit on one line; a spacer keeps them leading
        // while the row itself stretches with the fill-aligned column.
        let nameRow = UIStackView(arrangedSubviews: [nameLabel, verifiedBadge, UIView()])
        nameRow.axis = .horizontal
        nameRow.alignment = .center
        nameRow.spacing = Spacing.xs
        NSLayoutConstraint.activate([
            verifiedBadge.widthAnchor.constraint(equalToConstant: Metrics.badgeSize),
            verifiedBadge.heightAnchor.constraint(equalToConstant: Metrics.badgeSize)
        ])

        var websiteConfig = UIButton.Configuration.plain()
        websiteConfig.image = UIImage(systemName: "link")
        websiteConfig.imagePadding = Spacing.xs
        websiteConfig.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(textStyle: .footnote)
        websiteConfig.baseForegroundColor = .systemBlue
        websiteConfig.contentInsets = .zero
        websiteConfig.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
            var attributes = attributes
            attributes.font = UIFont.preferredFont(forTextStyle: .subheadline).withWeight(.semibold)
            return attributes
        }
        websiteButton.configuration = websiteConfig
        websiteButton.contentHorizontalAlignment = .leading
        websiteButton.isHidden = true
        websiteButton.addAction(
            UIAction { [weak self] _ in
                guard let self, let websiteURL = self.websiteURL else { return }
                self.onWebsiteTapped?(websiteURL)
            },
            for: .primaryActionTriggered
        )

        actionButton.isHidden = true
        actionButton.addAction(
            UIAction { [weak self] _ in self?.onActionTapped?() },
            for: .primaryActionTriggered
        )

        var messageConfig = Self.styledAction(.gray())
        messageConfig.title = "Message"
        messageButton.configuration = messageConfig
        messageButton.isHidden = true
        messageButton.addAction(
            UIAction { [weak self] _ in self?.onMessageTapped?() },
            for: .primaryActionTriggered
        )

        // Edge-to-edge action row: Follow + Message split it half-and-half;
        // when Message is hidden (own profile) Edit Profile takes the full width.
        let actionRow = UIStackView(arrangedSubviews: [actionButton, messageButton])
        actionRow.axis = .horizontal
        actionRow.alignment = .fill
        actionRow.distribution = .fillEqually
        actionRow.spacing = Spacing.sm
        // The row carries its own top gap: custom stack spacing would collapse
        // when the preceding bio/website rows are hidden.
        actionRow.isLayoutMarginsRelativeArrangement = true
        actionRow.directionalLayoutMargins = NSDirectionalEdgeInsets(
            top: Spacing.sm, leading: 0, bottom: 0, trailing: 0
        )

        let column = UIStackView(arrangedSubviews: [topRow, nameRow, bioLabel, websiteButton, actionRow])
        column.axis = .vertical
        column.alignment = .fill
        column.spacing = Spacing.xs
        column.setCustomSpacing(Spacing.md, after: topRow)

        column.pin(to: self, insets: NSDirectionalEdgeInsets(
            top: Spacing.md, leading: Spacing.lg, bottom: Spacing.lg, trailing: Spacing.lg
        ))
        NSLayoutConstraint.activate([
            avatarView.widthAnchor.constraint(equalToConstant: Metrics.avatarSize),
            avatarView.heightAnchor.constraint(equalToConstant: Metrics.avatarSize)
        ])
    }
}

private extension UIFont {
    func withWeight(_ weight: UIFont.Weight) -> UIFont {
        .systemFont(ofSize: pointSize, weight: weight)
    }
}
