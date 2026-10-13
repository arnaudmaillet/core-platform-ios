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

    /// The app's avatar (#943): the initials, then the picture over them.
    private let avatarView = AvatarView(size: .avatar)
    private let nameLabel = UILabel()
    private let handleLabel = UILabel()
    private let reasonLabel = UILabel()
    /// The app's button, shared with every person row (#932): Follow ⇄
    /// Following blurs over to the quiet ground, with the one press (#866).
    private let followButton: AppButton = {
        let button = AppButton(aspect: .pill(.prominent), size: .row, content: .title("Follow"))
        button.isToggle = true
        return button
    }()
    /// A bare ✕, quiet enough that the eye lands on Follow.
    private let dismissButton: AppButton = {
        let button = AppButton(aspect: .bare, size: .inline, content: .symbol("xmark"))
        button.inkColor = .tertiaryLabel
        return button
    }()
    /// Who the row shows and whether it said Following: the same person
    /// flipping cross-fades the button, a new person (a reused cell) does not.
    private var shownID: ProfileID?
    private var shownIsFollowing: Bool?

    private var imagePipeline: ImagePipeline?

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
        avatarView.reset()
    }

    func configure(with model: SuggestionDisplayModel, imagePipeline: ImagePipeline?) {
        self.imagePipeline = imagePipeline
        avatarView.setMonogram(model.monogram)
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

    /// Prominent while it invites, selected (quiet) once it states a fact —
    /// the same two looks as the relationship lists' rows.
    private func applyFollowState(_ isFollowing: Bool, name: String, animated: Bool) {
        followButton.setContent(.title(isFollowing ? "Following" : "Follow"), selected: isFollowing, animated: animated)
        followButton.accessibilityLabel = isFollowing ? "Unfollow \(name)" : "Follow \(name)"
    }

    /// The follow button. Internal for tests.
    var debugFollowButton: AppButton { followButton }
    /// The ✕. Internal for tests.
    var debugDismissButton: AppButton { dismissButton }
    /// The @handle line. Internal for tests.
    var debugHandleLabel: UILabel { handleLabel }
    /// The reason line. Internal for tests.
    var debugReasonLabel: UILabel { reasonLabel }

    /// The image dissolves in over the monogram, which stays behind it as the
    /// permanent fallback — a suggestion never renders as an empty disc.
    private func loadAvatar(_ url: URL?) {
        avatarView.setPicture(url, pipeline: imagePipeline)
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


        followButton.addAction(UIAction { [weak self] _ in self?.onToggleFollow?() }, for: .primaryActionTriggered)
        followButton.setContentHuggingPriority(.required, for: .horizontal)
        followButton.setContentCompressionResistancePriority(.required, for: .horizontal)

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

        let row = UIStackView(arrangedSubviews: [avatarView, textColumn, actions])
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
