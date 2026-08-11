import CoreModels
import DesignSystem
import MediaCore
import UIKit

/// One conversation, as a row — the whole visual definition, in one place.
///
/// ⚠️ **This is the row everywhere it appears.** The inbox list and the search
/// results used to build their own: a hand-laid `UITableViewCell` here, a
/// `UIListContentConfiguration` there. They agreed on the words and nothing
/// else — different fonts by different routes, a time label that was an
/// accessory in one and a column in the other, an avatar host of a different
/// class, and management glyphs that existed on one surface only. Two rows for
/// one thing is two places to fix everything and one place to forget.
///
/// The hosts keep only what is theirs: the table cell keeps the pinned band,
/// because that is its `backgroundView` and spans the accessory strip; the list
/// cell keeps nothing at all.
final class ConversationRowView: UIView {
    private let avatarView = BadgedAvatarView()
    private var avatarTask: Task<Void, Never>?
    /// The peer this row is currently showing. A reused row can outlive its own
    /// fetch, so the late result is checked against this before it draws —
    /// otherwise a slow avatar lands on whoever the row became.
    private var avatarPeerID: ProfileID?
    private let titleLabel = UILabel()
    private let previewLabel = UILabel()
    private let timeLabel = UILabel()
    private let mutedIcon = UIImageView(image: UIImage(systemName: "bell.slash.fill"))
    private let pinnedIcon = UIImageView(image: UIImage(systemName: "pin.fill"))

    override init(frame: CGRect) {
        super.init(frame: frame)
        buildLayout()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Cancels an avatar in flight and clears the face, for a host being reused.
    func prepareForReuse() {
        avatarTask?.cancel()
        avatarTask = nil
        avatarPeerID = nil
        avatarView.setPicture(nil, animated: false)
    }

    /// The row draws immediately from `model`; the picture, if there is one,
    /// arrives later through `avatars` and `imagePipeline`.
    ///
    /// ⚠️ **Both are optional and the row is complete without them.** The inbox
    /// is built from `chat.v1`, which carries no pictures at all — the avatar
    /// lives in `profile.v1` — so a list that waited for faces would hold every
    /// row behind a second service. The monogram is not a placeholder here; it
    /// is the rendered state, and the picture is an enhancement that may never
    /// come.
    ///
    /// Returns the row's accessibility label, which the host owns.
    @discardableResult
    func configure(
        with model: ConversationDisplayModel,
        imagePipeline: ImagePipeline? = nil,
        avatars: (any PeerAvatarProviding)? = nil
    ) -> String {
        avatarView.setMonogram(model.monogram)
        loadAvatar(for: model, imagePipeline: imagePipeline, avatars: avatars)
        titleLabel.text = model.title
        previewLabel.text = model.preview.isEmpty ? "No messages yet" : model.preview
        timeLabel.text = model.timeText
        mutedIcon.isHidden = !model.isMuted
        applyUnreadStyle(model.isUnread)
        // The COUNT, not just presence — `chat.v1` still serves no
        // `unread_count`, so this is counted from the history tail the inbox
        // already fetches (`Conversation.unreadCount`).
        avatarView.setBadge(model.isUnread ? .count(model.unreadCount) : .none)
        pinnedIcon.isHidden = !model.isPinned

        let states: [String?] = [
            model.title,
            model.isUnread ? "Unread" : nil,
            model.isPinned ? "Pinned" : nil,
            model.isMuted ? "Muted" : nil,
            model.timeText,
            model.preview
        ]
        return states.compactMap(\.self).filter { !$0.isEmpty }.joined(separator: ", ")
    }

    /// The pin glyph alone; the band belongs to the host that has a background.
    func setPinnedIconHidden(_ isHidden: Bool) {
        pinnedIcon.isHidden = isHidden
    }

    /// Unread rows carry weight and full-strength colour; read rows recede.
    /// Only the fonts and colours change — nothing moves — so a row switching
    /// state can't shift the rows around it.
    private func applyUnreadStyle(_ isUnread: Bool) {
        titleLabel.font = isUnread
            ? .preferredFont(forTextStyle: .headline, weight: .bold)
            : .preferredFont(forTextStyle: .headline)
        previewLabel.font = isUnread
            ? .preferredFont(forTextStyle: .subheadline, weight: .semibold)
            : .preferredFont(forTextStyle: .subheadline)
        previewLabel.textColor = isUnread ? .label : .secondaryLabel
        timeLabel.textColor = isUnread ? .label : .secondaryLabel
    }

    /// Resolves the peer's avatar URL, then its image, then draws it — each
    /// step abandoned if the row has moved on.
    private func loadAvatar(
        for model: ConversationDisplayModel,
        imagePipeline: ImagePipeline?,
        avatars: (any PeerAvatarProviding)?
    ) {
        avatarTask?.cancel()
        avatarTask = nil
        avatarPeerID = model.peerID
        avatarView.setPicture(nil, animated: false)

        guard let peerID = model.peerID, let avatars, let imagePipeline else { return }
        avatarTask = Task { [weak self] in
            let urls = await avatars.avatarURLs(for: [peerID])
            guard !Task.isCancelled, let url = urls[peerID] else { return }
            guard let image = try? await imagePipeline.image(for: url) else { return }
            guard let self, !Task.isCancelled, self.avatarPeerID == peerID else { return }
            self.avatarView.setPicture(image, animated: true)
        }
    }

    private func buildLayout() {
        titleLabel.textColor = .label
        previewLabel.numberOfLines = 1
        timeLabel.setContentHuggingPriority(.required, for: .horizontal)
        for label in [titleLabel, previewLabel, timeLabel] {
            label.adjustsFontForContentSizeCategory = true
        }
        timeLabel.font = .preferredFont(forTextStyle: .footnote)
        applyUnreadStyle(false)

        // Status glyphs (all hidden by default). BOTH live in the trailing
        // column, under the time — muted used to sit inline after the title,
        // which put the row's two management marks at opposite ends of it and
        // made neither scannable. Together they read as one group.
        for icon in [mutedIcon, pinnedIcon] {
            icon.preferredSymbolConfiguration = UIImage.SymbolConfiguration(textStyle: .caption1)
            icon.tintColor = .secondaryLabel
            icon.contentMode = .scaleAspectFit
            icon.isHidden = true
            icon.setContentHuggingPriority(.required, for: .horizontal)
            icon.setContentCompressionResistancePriority(.required, for: .horizontal)
        }

        let textColumn = UIStackView(arrangedSubviews: [titleLabel, previewLabel])
        textColumn.axis = .vertical
        textColumn.spacing = 2

        // `[mute][pin]`, in that order, reading toward the row's edge — mute is
        // the quieter statement and sits inboard of the pin, which is the one
        // that also tints the whole row.
        //
        // Center, not firstBaseline: the glyph image views have no baseline.
        let glyphRow = UIStackView(arrangedSubviews: [mutedIcon, pinnedIcon])
        glyphRow.axis = .horizontal
        glyphRow.alignment = .center
        glyphRow.spacing = Spacing.xs

        // Time over the glyphs, pushed to the row's trailing edge. The stack
        // keeps its width when a glyph hides, so toggling either can never
        // reflow the title/preview column beside it.
        let statusColumn = UIStackView(arrangedSubviews: [timeLabel, glyphRow])
        statusColumn.axis = .vertical
        statusColumn.alignment = .trailing
        statusColumn.spacing = Spacing.xs
        statusColumn.setContentHuggingPriority(.required, for: .horizontal)
        statusColumn.setContentCompressionResistancePriority(.required, for: .horizontal)

        let row = UIStackView(arrangedSubviews: [avatarView, textColumn, statusColumn])
        row.axis = .horizontal
        row.alignment = .center
        row.spacing = Spacing.md
        // The disc is the tallest thing here — a title over a preview does not
        // clear 48pt — so it is what the row is padded around. Both hosts get
        // this number, which is what makes their heights identical.
        let inset = PersonRowMetrics.verticalInset(
            forContentHeight: MonogramAvatarView.rowDiameter
        )
        row.pin(to: self, insets: NSDirectionalEdgeInsets(
            top: inset, leading: Spacing.lg, bottom: inset, trailing: Spacing.lg
        ))
    }
}

private extension UIFont {
    static func preferredFont(forTextStyle style: TextStyle, weight: Weight) -> UIFont {
        let metrics = UIFontMetrics(forTextStyle: style)
        let base = UIFont.systemFont(
            ofSize: UIFont.preferredFont(forTextStyle: style).pointSize, weight: weight
        )
        return metrics.scaledFont(for: base)
    }
}
