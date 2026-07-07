import CoreMedia
import DesignSystem
import UIKit

/// The profile identity block: avatar, name + verified badge, @handle, bio, and
/// the followers/following counter row. Pure presentation — it is handed a
/// finished `ProfileDisplayModel` and an `ImagePipeline`; it owns no data.
final class ProfileHeaderView: UIView {
    private enum Metrics {
        static let avatarSize: CGFloat = 88
    }

    private let avatarView = UIImageView()
    private let monogramLabel = UILabel()
    private let nameLabel = UILabel()
    private let verifiedBadge = UIImageView(image: UIImage(systemName: "checkmark.seal.fill"))
    private let handleLabel = UILabel()
    private let bioLabel = UILabel()
    private let followersStat = ProfileStatView(caption: "Followers")
    private let followingStat = ProfileStatView(caption: "Following")
    private let actionButton = UIButton(configuration: .filled())

    /// Invoked when the Follow / Following / Edit Profile button is tapped.
    var onActionTapped: (() -> Void)?

    private let imagePipeline: ImagePipeline
    private var avatarTask: Task<Void, Never>?
    private var currentAvatarURL: URL?

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
        handleLabel.text = model.handle

        bioLabel.text = model.bio
        bioLabel.isHidden = !model.hasBio

        followersStat.setValue(model.followerText)
        followingStat.setValue(model.followingText)

        loadAvatar(model.avatarURL)
    }

    /// Styles the action button per the viewer's relationship. `.follow` is the
    /// one prominent (filled) call to action; Following/Edit are secondary.
    func configureAction(_ state: ProfileViewModel.FollowButton) {
        switch state {
        case .hidden:
            actionButton.isHidden = true
        case .follow:
            actionButton.isHidden = false
            applyActionStyle(title: "Follow", prominent: true)
        case .following:
            actionButton.isHidden = false
            applyActionStyle(title: "Following", prominent: false)
        case .edit:
            actionButton.isHidden = false
            applyActionStyle(title: "Edit Profile", prominent: false)
        }
    }

    private func applyActionStyle(title: String, prominent: Bool) {
        var config: UIButton.Configuration = prominent ? .filled() : .gray()
        config.title = title
        config.cornerStyle = .capsule
        config.buttonSize = .medium
        config.contentInsets = NSDirectionalEdgeInsets(
            top: Spacing.sm, leading: Spacing.xl, bottom: Spacing.sm, trailing: Spacing.xl
        )
        if prominent {
            config.baseBackgroundColor = .systemBlue
            config.baseForegroundColor = .white
        }
        actionButton.configuration = config
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

        nameLabel.font = .preferredFont(forTextStyle: .title2)
        nameLabel.adjustsFontForContentSizeCategory = true
        nameLabel.font = UIFont.boldSystemFont(ofSize: UIFont.preferredFont(forTextStyle: .title2).pointSize)
        nameLabel.textColor = .label
        nameLabel.numberOfLines = 1

        verifiedBadge.tintColor = .systemBlue
        verifiedBadge.contentMode = .scaleAspectFit
        verifiedBadge.setContentHuggingPriority(.required, for: .horizontal)

        handleLabel.font = .preferredFont(forTextStyle: .subheadline)
        handleLabel.adjustsFontForContentSizeCategory = true
        handleLabel.textColor = .secondaryLabel

        bioLabel.font = .preferredFont(forTextStyle: .body)
        bioLabel.adjustsFontForContentSizeCategory = true
        bioLabel.textColor = .label
        bioLabel.numberOfLines = 0

        // Name + verified badge sit on one line, left-aligned.
        let nameRow = UIStackView(arrangedSubviews: [nameLabel, verifiedBadge])
        nameRow.axis = .horizontal
        nameRow.alignment = .center
        nameRow.spacing = Spacing.xs
        NSLayoutConstraint.activate([
            verifiedBadge.widthAnchor.constraint(equalToConstant: 20),
            verifiedBadge.heightAnchor.constraint(equalToConstant: 20)
        ])

        let statsRow = UIStackView(arrangedSubviews: [followersStat, followingStat, UIView()])
        statsRow.axis = .horizontal
        statsRow.alignment = .center
        statsRow.spacing = Spacing.xl
        statsRow.distribution = .fill

        actionButton.isHidden = true
        actionButton.setContentHuggingPriority(.required, for: .horizontal)
        actionButton.addAction(
            UIAction { [weak self] _ in self?.onActionTapped?() },
            for: .primaryActionTriggered
        )

        let column = UIStackView(arrangedSubviews: [avatarView, nameRow, handleLabel, bioLabel, statsRow, actionButton])
        column.axis = .vertical
        column.alignment = .leading
        column.spacing = Spacing.sm
        column.setCustomSpacing(Spacing.md, after: avatarView)
        column.setCustomSpacing(Spacing.md, after: handleLabel)
        column.setCustomSpacing(Spacing.lg, after: bioLabel)
        column.setCustomSpacing(Spacing.lg, after: statsRow)

        column.pin(to: self, insets: NSDirectionalEdgeInsets(
            top: Spacing.lg, leading: Spacing.lg, bottom: Spacing.lg, trailing: Spacing.lg
        ))
        NSLayoutConstraint.activate([
            avatarView.widthAnchor.constraint(equalToConstant: Metrics.avatarSize),
            avatarView.heightAnchor.constraint(equalToConstant: Metrics.avatarSize)
        ])
    }
}
