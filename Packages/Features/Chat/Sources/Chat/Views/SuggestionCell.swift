import CoreModels
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
    /// UIKit's system capsule, shared with every person row (#885): Follow ⇄
    /// Following cross-fades, and its press is the configuration's highlight.
    private let followButton = RowActionButton(frame: .zero)
    private let dismissButton = RowActionButton(frame: .zero)
    /// Who the row shows and whether it said Following: the same person
    /// flipping cross-fades the button, a new person (a reused cell) does not.
    private var shownID: ProfileID?
    private var shownIsFollowing: Bool?

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
        // A reconfigure keeps the cell without coming through here, so only
        // a real reuse forgets who the row showed.
        shownID = nil
        shownIsFollowing = nil
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
        // Hidden, not empty: a stack skips a hidden arranged subview, so a
        // missing line takes its gap with it.
        handleLabel.isHidden = model.handleText.isEmpty
        reasonLabel.isHidden = model.reasonText.isEmpty
        let flips = shownID == model.id && shownIsFollowing != nil && shownIsFollowing != model.isFollowing
        applyFollowState(model.isFollowing, name: model.displayName, animated: flips)
        shownID = model.id
        shownIsFollowing = model.isFollowing
        dismissButton.accessibilityLabel = "Remove suggestion \(model.displayName)"
        loadAvatar(model.avatarURL)
    }

    private func applyFollowState(_ isFollowing: Bool, name: String, animated: Bool) {
        followButton.setConfiguration(Self.followConfiguration(isFollowing: isFollowing), animated: animated)
        followButton.accessibilityLabel = isFollowing ? "Unfollow \(name)" : "Follow \(name)"
    }

    /// Filled while it invites, grey once it states a fact — the same two
    /// looks as the relationship lists' rows.
    private static func followConfiguration(isFollowing: Bool) -> UIButton.Configuration {
        isFollowing
            ? RowActionButton.configuration(title: "Following", prominence: .secondary)
            : RowActionButton.configuration(title: "Follow", prominence: .prominent)
    }

    /// The follow button. Internal for tests.
    var debugFollowButton: RowActionButton { followButton }
    /// The ✕. Internal for tests.
    var debugDismissButton: RowActionButton { dismissButton }
    /// The @handle line. Internal for tests.
    var debugHandleLabel: UILabel { handleLabel }
    /// The reason line. Internal for tests.
    var debugReasonLabel: UILabel { reasonLabel }

    /// The image dissolves in over the monogram, which stays behind it as the
    /// permanent fallback — a suggestion never renders as an empty disc.
    private func loadAvatar(_ url: URL?) {
        guard url != currentAvatarURL || avatarView.image == nil else { return }
        currentAvatarURL = url
        avatarTask?.cancel()
        avatarView.image = nil

        guard let url, let pipeline = imagePipeline else { return }
        avatarTask = Task { [weak self] in
            guard let image = try? await pipeline.image(for: url, size: .avatar) else { return }
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
        nameLabel.font = .appFont(forTextStyle: .headline)
        nameLabel.textColor = .label

        handleLabel.font = .appFont(forTextStyle: .subheadline)
        handleLabel.textColor = .secondaryLabel

        // Same size as the handle, one colour step quieter — the reason
        // belongs with the handle, not to a third tier of type.
        reasonLabel.font = .appFont(forTextStyle: .subheadline)
        reasonLabel.textColor = .tertiaryLabel

        for label in [nameLabel, handleLabel, reasonLabel] {
            label.adjustsFontForContentSizeCategory = true
            label.numberOfLines = 1
            // Each line has the column to itself and gives way to the
            // buttons, never the other way round.
            label.lineBreakMode = .byTruncatingTail
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
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
        dismissButton.setConfiguration(dismissConfiguration, animated: false)
        dismissButton.addAction(UIAction { [weak self] _ in self?.onDismiss?() }, for: .primaryActionTriggered)
        dismissButton.setContentHuggingPriority(.required, for: .horizontal)
        dismissButton.setContentCompressionResistancePriority(.required, for: .horizontal)

        // ⚠️ THE REASON HAS ITS OWN LINE, UNDER THE HANDLE (#915). It sat
        // inline after the handle (`@handle • reason`, the search rows'
        // shape), and the handle was the part that gave way: the text column
        // is ~190 pt at 402 and ~160 at 375, "2 mutual connections" alone
        // takes ~150, so every row read "@…  • 2 mutual connections". No
        // split of one line keeps both readable — at 375 a whole handle
        // leaves the reason "2 mu…", a six-character handle still cuts it to
        // "2 mutual co…" — and the count IS the reason. One more line of type
        // costs the row a few points over the shared pitch.
        let textColumn = UIStackView(arrangedSubviews: [nameLabel, handleLabel, reasonLabel])
        textColumn.axis = .vertical
        textColumn.spacing = 2
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
        // Three lines of type are taller than the disc, so they are what the
        // row is padded around — the same arithmetic as every other people
        // list in the app.
        let inset = PersonRowMetrics.verticalInset(forContentHeight: max(
            MonogramAvatarView.rowDiameter,
            PersonRowMetrics.textHeight([.headline, .subheadline, .subheadline]) + textColumn.spacing * 2
        ))
        row.pin(to: contentView, insets: NSDirectionalEdgeInsets(
            top: inset, leading: Spacing.lg, bottom: inset, trailing: Spacing.lg
        ))
    }
}
