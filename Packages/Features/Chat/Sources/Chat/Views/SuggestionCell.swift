import DesignSystem
import Foundation
import MediaCore
import UIKit

/// A suggested account: avatar, identity, the reason it's being suggested, and
/// the two decisions — follow, or make it go away.
///
/// The reason line is not decoration. A recommendation the viewer can't
/// account for reads as an ad; "Follows you" or "Followed by Ava + 2" is what
/// turns it back into a suggestion.
final class SuggestionCell: UITableViewCell {
    static let reuseIdentifier = "SuggestionCell"

    var onToggleFollow: (() -> Void)?
    var onDismiss: (() -> Void)?

    private let monogramView = MonogramAvatarView()
    private let avatarView = AvatarImageView()
    private let nameLabel = UILabel()
    private let handleLabel = UILabel()
    private let reasonLabel = UILabel()
    private let followButton = UIButton(type: .system)
    private let dismissButton = UIButton(type: .system)

    private var imagePipeline: ImagePipeline?
    private var currentAvatarURL: URL?
    private var avatarTask: Task<Void, Never>?

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        configure()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func prepareForReuse() {
        super.prepareForReuse()
        onToggleFollow = nil
        onDismiss = nil
        avatarTask?.cancel()
        avatarTask = nil
        currentAvatarURL = nil
        avatarView.image = nil
    }

    func configure(with model: SuggestionDisplayModel, imagePipeline: ImagePipeline?) {
        self.imagePipeline = imagePipeline
        monogramView.setMonogram(model.monogram)
        nameLabel.text = model.displayName
        handleLabel.text = model.handleText
        reasonLabel.text = model.reasonText
        applyFollowState(model.isFollowing, name: model.displayName)
        dismissButton.accessibilityLabel = "Remove suggestion \(model.displayName)"
        loadAvatar(model.avatarURL)
    }

    private func applyFollowState(_ isFollowing: Bool, name: String) {
        var configuration: UIButton.Configuration = isFollowing ? .gray() : .borderedProminent()
        configuration.cornerStyle = .capsule
        configuration.buttonSize = .small
        configuration.attributedTitle = AttributedString(
            isFollowing ? "Following" : "Follow",
            attributes: AttributeContainer([
                .font: UIFont.preferredFont(forTextStyle: .subheadline)
            ])
        )
        followButton.configuration = configuration
        followButton.accessibilityLabel = isFollowing ? "Unfollow \(name)" : "Follow \(name)"
    }

    /// The image dissolves in over the monogram, which stays behind it as the
    /// permanent fallback — a suggestion never renders as an empty disc.
    private func loadAvatar(_ url: URL?) {
        guard url != currentAvatarURL || avatarView.image == nil else { return }
        currentAvatarURL = url
        avatarTask?.cancel()
        avatarView.image = nil

        guard let url, let pipeline = imagePipeline else { return }
        avatarTask = Task { [weak self] in
            guard let image = try? await pipeline.image(for: url) else { return }
            guard let self, !Task.isCancelled, self.currentAvatarURL == url else { return }
            UIView.transition(
                with: self.avatarView, duration: 0.25,
                options: [.transitionCrossDissolve, .allowUserInteraction]
            ) {
                self.avatarView.image = image
            }
        }
    }

    private func configure() {
        nameLabel.font = .preferredFont(forTextStyle: .headline)
        nameLabel.textColor = .label

        handleLabel.font = .preferredFont(forTextStyle: .subheadline)
        handleLabel.textColor = .secondaryLabel

        reasonLabel.font = .preferredFont(forTextStyle: .footnote)
        reasonLabel.textColor = .tertiaryLabel

        for label in [nameLabel, handleLabel, reasonLabel] {
            label.adjustsFontForContentSizeCategory = true
            label.numberOfLines = 1
        }

        // The image overlays the monogram exactly, so the fallback is a layer
        // behind rather than a swap.
        avatarView.pin(to: monogramView)

        followButton.addAction(UIAction { [weak self] _ in self?.onToggleFollow?() }, for: .primaryActionTriggered)
        followButton.setContentHuggingPriority(.required, for: .horizontal)
        followButton.setContentCompressionResistancePriority(.required, for: .horizontal)

        var dismissConfiguration = UIButton.Configuration.plain()
        dismissConfiguration.image = UIImage(systemName: "xmark")
        dismissConfiguration.baseForegroundColor = .tertiaryLabel
        dismissConfiguration.buttonSize = .small
        dismissButton.configuration = dismissConfiguration
        dismissButton.addAction(UIAction { [weak self] _ in self?.onDismiss?() }, for: .primaryActionTriggered)
        dismissButton.setContentHuggingPriority(.required, for: .horizontal)

        let textColumn = UIStackView(arrangedSubviews: [nameLabel, handleLabel, reasonLabel])
        textColumn.axis = .vertical
        textColumn.spacing = 1
        textColumn.alignment = .leading

        let actions = UIStackView(arrangedSubviews: [followButton, dismissButton])
        actions.axis = .horizontal
        actions.spacing = Spacing.xs
        actions.alignment = .center
        actions.setContentHuggingPriority(.required, for: .horizontal)

        let row = UIStackView(arrangedSubviews: [monogramView, textColumn, actions])
        row.axis = .horizontal
        row.alignment = .center
        row.spacing = Spacing.md
        // ⚠️ THREE lines here — name, handle, and the reason the person is
        // being suggested — which is taller than the disc and leaves the least
        // room to pad. The shared minimum is what keeps this row from being
        // squeezed below what its own content needs.
        let inset = PersonRowMetrics.verticalInset(forContentHeight: max(
            MonogramAvatarView.rowDiameter,
            PersonRowMetrics.textHeight([.headline, .subheadline, .footnote])
        ))
        row.pin(to: contentView, insets: NSDirectionalEdgeInsets(
            top: inset, leading: Spacing.lg, bottom: inset, trailing: Spacing.lg
        ))
    }
}
