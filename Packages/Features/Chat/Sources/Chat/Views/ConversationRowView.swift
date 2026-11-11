import CoreModels
import DesignSystem
import EmoteKit
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
    /// The face, wearing the relation mark (#2049): the unread count left it
    /// for the trailing column (`unreadPill`).
    private let avatarView = RelationMarkedAvatarView()
    /// A group's picture over the face's place (#2233): its photo, its
    /// members' faces cut apart, or its initials — the shared component the
    /// thread's pill draws too. A sibling laid over the face rather than
    /// inside it: the face draws nothing but its avatar and its badge.
    private let groupAvatar = GroupAvatarView()
    private var avatarTask: Task<Void, Never>?
    /// The peer this row is currently showing. A reused row can outlive its own
    /// fetch, so the late result is checked against this before it draws —
    /// otherwise a slow avatar lands on whoever the row became.
    private var avatarPeerID: ProfileID?
    private let titleLabel = UILabel()
    /// The last message's emotes animate (`EmoteLabel` marks plain `text`).
    private let previewLabel = EmoteLabel()
    private let timeLabel = UILabel()
    private let mutedIcon = UIImageView(image: UIImage(systemName: "bell.slash.fill"))
    private let pinnedIcon = UIImageView(image: UIImage(systemName: "pin.fill"))
    /// The unread count, under the time at the row's trailing edge (#2049).
    private let unreadPill = UnreadCountPill()
    /// A channel (#2215): a small megaphone right after its name — on every
    /// channel since #2230, where it marked only the ones the viewer runs.
    private let channelBadge = UIImageView(image: UIImage(systemName: ConversationRowView.channelBadgeSymbol))

    /// The mark of a channel: a megaphone — one voice, to everyone who
    /// follows it. Every channel wears it in Chats (#2230): mixed with the
    /// DMs and the groups, it is what says a row is read, not answered.
    static let channelBadgeSymbol = "megaphone.fill"

    /// Told when the face's "+" is tapped — never the row's own tap.
    var onFollowTapped: (() -> Void)? {
        get { avatarView.onFollowTapped }
        set { avatarView.onFollowTapped = newValue }
    }

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
        avatarView.setPicture(nil, pipeline: nil)
        groupAvatar.setContent(nil, pipeline: nil)
        // A reused row starts unknown for its next person, never wearing
        // the previous one's mark (#2098).
        avatarView.setMark(.loading, animated: false)
        onFollowTapped = nil
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
    /// `mark`: the relation the face wears (#2049) — `.none` for a group, a
    /// relation not known yet, or a host with no graph.
    ///
    /// Returns the row's accessibility label, which the host owns.
    @discardableResult
    func configure(
        with model: ConversationDisplayModel,
        imagePipeline: ImagePipeline? = nil,
        avatars: (any PeerAvatarProviding)? = nil,
        mark: PersonPill.Badge = .none
    ) -> String {
        avatarView.setMonogram(model.monogram)
        // A group keeps its initials, with no mark.
        avatarView.setMark(model.peerID == nil ? .none : mark, animated: false)
        // A group wears its picture (#2233); the face's place stays laid
        // out under it, so nothing moves.
        let isGroup = model.groupAvatar != nil
        groupAvatar.setContent(model.groupAvatar, pipeline: imagePipeline)
        groupAvatar.isHidden = !isGroup
        avatarView.alpha = isGroup ? 0 : 1
        if isGroup {
            // Under the group's picture: nothing to load.
            avatarTask?.cancel()
            avatarTask = nil
            avatarPeerID = nil
            avatarView.setPicture(nil, pipeline: nil)
        } else {
            loadAvatar(for: model, imagePipeline: imagePipeline, avatars: avatars)
        }
        titleLabel.text = model.title
        channelBadge.isHidden = !model.isChannel
        let preview = model.preview.isEmpty ? "No messages yet" : model.previewLine
        if let voice = Self.voicePreview(model.preview) {
            // A group's voice message keeps its sender (#2214).
            let line = NSMutableAttributedString(string: model.previewSender.map { "\($0): " } ?? "")
            line.append(voice)
            previewLabel.attributedText = line
        } else {
            previewLabel.text = preview
        }
        timeLabel.text = model.timeText
        mutedIcon.isHidden = !model.isMuted
        applyUnreadStyle(model.isUnread)
        // The COUNT, not just presence — `chat.v1` still serves no
        // `unread_count`, so this is counted from the history tail the inbox
        // already fetches (`Conversation.unreadCount`). Never at zero.
        // Its ink (#2292): the primary only on a row new since the visit and
        // not muted, grey on every other unread row; the bold stays on all.
        if let ink = model.unreadInk, model.unreadCount > 0 {
            unreadPill.show(count: model.unreadCount, ink: ink)
        } else {
            unreadPill.hide()
        }
        pinnedIcon.isHidden = !model.isPinned

        let states: [String?] = [
            model.title,
            Self.channelWords(model),
            Self.unreadWords(model),
            model.isPinned ? "Pinned" : nil,
            model.isMuted ? "Muted" : nil,
            model.timeText,
            model.previewLine
        ]
        return states.compactMap(\.self).filter { !$0.isEmpty }.joined(separator: ", ")
    }

    /// "Channel", or "Channel, you run it" (#2230); nil for a DM or a group.
    static func channelWords(_ model: ConversationDisplayModel) -> String? {
        guard model.isChannel else { return nil }
        return model.runsChannel ? "Channel, you run it" : "Channel"
    }

    /// "3 new unread" for a count in the primary, "3 unread" for a grey one
    /// (#2292); "Unread" when there is no count; nil when read. "Muted" is
    /// said on its own.
    static func unreadWords(_ model: ConversationDisplayModel) -> String? {
        guard let ink = model.unreadInk else { return nil }
        guard model.unreadCount > 0 else { return "Unread" }
        return ink == .primary ? "\(model.unreadCount) new unread" : "\(model.unreadCount) unread"
    }

    /// The relation the face wears, through the badge's replace and the
    /// ring's fade on screen — the row draws first and the mark arrives,
    /// moving nothing (#2049).
    func setRelationMark(_ mark: PersonPill.Badge, animated: Bool) {
        avatarView.setMark(mark, animated: animated)
    }

    /// The mark on show.
    var relationMark: PersonPill.Badge { avatarView.mark }

    /// VoiceOver's way to the "+" (the row is the element, and its tap
    /// opens the conversation): a "Follow" action while the face shows it.
    var followAccessibilityActions: [UIAccessibilityCustomAction]? {
        guard relationMark == .follow, onFollowTapped != nil else { return nil }
        return [UIAccessibilityCustomAction(name: "Follow") { [weak self] _ in
            self?.onFollowTapped?()
            return true
        }]
    }

    /// ⚠️ THE "+" IS ASKED FIRST. Its touch area (grown by 8 pt) reaches past
    /// the 48 pt disc, and past the stack the disc is laid out in, which
    /// would refuse the touch before the badge saw it. Within the row, a
    /// touch on the "+" is the badge's; everything else stays the row's (its
    /// tap, swipe actions and context menu).
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        if let badge = avatarView.tappableBadge, !isHidden, alpha > 0.01,
           badge.point(inside: convert(point, to: badge), with: event) {
            return badge
        }
        return super.hitTest(point, with: event)
    }

    /// The pin glyph alone; the band belongs to the host that has a background.
    func setPinnedIconHidden(_ isHidden: Bool) {
        pinnedIcon.isHidden = isHidden
    }

    /// A voice message's preview — the server's "🎤 Voice message (0:12)" —
    /// with the waveform symbol for the microphone (the owner, 2026-11-07).
    /// A template image: it takes the line's colour and its unread weight
    /// as the words do. Nil for any other preview.
    static func voicePreview(_ preview: String) -> NSAttributedString? {
        let microphone = "🎤 "
        guard preview.hasPrefix(microphone),
              let symbol = UIImage(
                  systemName: "waveform",
                  withConfiguration: UIImage.SymbolConfiguration(textStyle: .subheadline, scale: .small)
              ) else { return nil }
        let line = NSMutableAttributedString(attachment: NSTextAttachment(image: symbol))
        line.append(NSAttributedString(string: " " + preview.dropFirst(microphone.count)))
        return line
    }

    /// Unread rows carry weight and full-strength colour; read rows recede.
    /// Only the fonts and colours change — nothing moves — so a row switching
    /// state can't shift the rows around it.
    private func applyUnreadStyle(_ isUnread: Bool) {
        titleLabel.font = isUnread
            ? .preferredFont(forTextStyle: .headline, weight: .bold)
            : .appFont(forTextStyle: .headline)
        previewLabel.font = isUnread
            ? .preferredFont(forTextStyle: .subheadline, weight: .semibold)
            : .appFont(forTextStyle: .subheadline)
        previewLabel.textColor = isUnread ? .label : .secondaryLabel
        timeLabel.textColor = isUnread ? .label : .secondaryLabel
    }

    /// Resolves the peer's avatar URL, then hands it to the avatar, which
    /// loads and draws it — abandoned if the row has moved on.
    private func loadAvatar(
        for model: ConversationDisplayModel,
        imagePipeline: ImagePipeline?,
        avatars: (any PeerAvatarProviding)?
    ) {
        // The same person again (a snapshot reconfiguring the row): their
        // face, or the lookup for it, is under way or answered.
        if let peerID = model.peerID, peerID == avatarPeerID, avatarTask != nil {
            return
        }
        avatarTask?.cancel()
        avatarTask = nil
        avatarPeerID = model.peerID

        // A group's own photo is already a URL (#2214): no lookup.
        if let photo = model.groupPhotoURL {
            avatarView.setPicture(photo, pipeline: imagePipeline)
            return
        }
        guard let peerID = model.peerID, let avatars, let imagePipeline else {
            avatarView.setPicture(nil, pipeline: nil)
            return
        }
        // The URL lives in profile.v1, a second service: the skeleton holds
        // the face's place meanwhile, never the initials (#1750).
        avatarView.awaitPicture()
        avatarTask = Task { [weak self] in
            let urls = await avatars.avatarURLs(for: [peerID])
            guard let self, !Task.isCancelled, self.avatarPeerID == peerID else { return }
            // No picture: the initials. The finished task stays as the
            // peer's answer: a reconfigure for the same person keeps it,
            // where a fresh lookup flickered pictureless rows' initials.
            self.avatarView.setPicture(urls[peerID], pipeline: imagePipeline)
        }
    }

    private func buildLayout() {
        titleLabel.textColor = .label
        previewLabel.numberOfLines = 1
        timeLabel.setContentHuggingPriority(.required, for: .horizontal)
        for label in [titleLabel, previewLabel, timeLabel] {
            label.adjustsFontForContentSizeCategory = true
        }
        timeLabel.font = .appFont(forTextStyle: .footnote)
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

        // The name, then the channel's megaphone right after it (#2215,
        // #2230); the spacer takes what is left, so the badge follows the
        // name, not the column.
        channelBadge.preferredSymbolConfiguration = UIImage.SymbolConfiguration(textStyle: .caption1)
        channelBadge.tintColor = .tintColor
        channelBadge.contentMode = .scaleAspectFit
        channelBadge.isHidden = true
        channelBadge.setContentHuggingPriority(.required, for: .horizontal)
        channelBadge.setContentCompressionResistancePriority(.required, for: .horizontal)
        let titleSpacer = UIView()
        titleSpacer.setContentHuggingPriority(.defaultLow - 1, for: .horizontal)
        titleSpacer.setContentCompressionResistancePriority(.defaultLow - 1, for: .horizontal)
        let titleRow = UIStackView(arrangedSubviews: [titleLabel, channelBadge, titleSpacer])
        titleRow.axis = .horizontal
        titleRow.alignment = .center
        titleRow.spacing = Spacing.xs

        let textColumn = UIStackView(arrangedSubviews: [titleRow, previewLabel])
        textColumn.axis = .vertical
        textColumn.spacing = 2

        // `[mute][pin][count]`, in that order, reading toward the row's edge —
        // mute is the quieter statement and sits inboard of the pin, which is
        // the one that also tints the whole row; the count (#2049) takes the
        // trailing edge, under the time's.
        //
        // Center, not firstBaseline: the glyph image views have no baseline.
        let glyphRow = UIStackView(arrangedSubviews: [mutedIcon, pinnedIcon, unreadPill])
        glyphRow.axis = .horizontal
        glyphRow.alignment = .center
        glyphRow.spacing = Spacing.xs

        // ⚠️ THE SECOND LINE KEEPS ITS HEIGHT, pill or not (#2049): at least
        // the pill's, so an unread row and a read one put the time at the
        // same height, and a count arriving moves nothing.
        let secondLine = UIView()
        secondLine.addSubview(glyphRow)
        glyphRow.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            secondLine.heightAnchor.constraint(greaterThanOrEqualToConstant: UnreadCountPill.Metrics.height),
            glyphRow.topAnchor.constraint(greaterThanOrEqualTo: secondLine.topAnchor),
            glyphRow.bottomAnchor.constraint(lessThanOrEqualTo: secondLine.bottomAnchor),
            glyphRow.centerYAnchor.constraint(equalTo: secondLine.centerYAnchor),
            glyphRow.leadingAnchor.constraint(equalTo: secondLine.leadingAnchor),
            glyphRow.trailingAnchor.constraint(equalTo: secondLine.trailingAnchor)
        ])
        let collapse = secondLine.heightAnchor.constraint(equalToConstant: 0)
        collapse.priority = .defaultLow
        collapse.isActive = true

        // Time over the second line, pushed to the row's trailing edge. The
        // stack keeps its width when a glyph hides, so toggling either can
        // never reflow the title/preview column beside it.
        let statusColumn = UIStackView(arrangedSubviews: [timeLabel, secondLine])
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
        groupAvatar.isHidden = true
        // The row is the element: it says the group's name.
        groupAvatar.isAccessibilityElement = false
        groupAvatar.constrain(in: self) { _ in
            groupAvatar.leadingAnchor.constraint(equalTo: avatarView.leadingAnchor)
            groupAvatar.trailingAnchor.constraint(equalTo: avatarView.trailingAnchor)
            groupAvatar.topAnchor.constraint(equalTo: avatarView.topAnchor)
            groupAvatar.bottomAnchor.constraint(equalTo: avatarView.bottomAnchor)
        }
    }
}

#if DEBUG
extension ConversationRowView {
    /// The count's pill. Tests.
    var debugUnreadPill: UnreadCountPill? { unreadPill }
    /// The time. Tests.
    var debugTimeLabel: UILabel { timeLabel }
    /// The muted and pinned glyphs on show. Tests.
    var debugGlyphs: [UIImageView] { [mutedIcon, pinnedIcon].filter { !$0.isHidden } }
    /// The face's badge. Tests.
    var debugBadge: RelationBadgeView? { avatarView.badge }
    /// Whether the face has the badge's cutout taken out. Tests.
    var debugFaceIsCutOut: Bool { avatarView.faceIsCutOut }
    /// The members' faces stacked, while a photoless group shows them. Tests.
    var debugStackedFaceCount: Int { groupAvatar.isHidden ? 0 : groupAvatar.drawnFaceCount }
    /// The group's picture, while the row shows a group (#2233). Tests.
    var debugGroupAvatar: GroupAvatarView? { groupAvatar.isHidden ? nil : groupAvatar }
    /// The preview line. Tests.
    var debugPreviewText: String? { previewLabel.attributedText?.string ?? previewLabel.text }
    /// Whether the channel's megaphone shows (#2215, #2230). Tests.
    var debugShowsChannelBadge: Bool { !channelBadge.isHidden }
    /// Whether the row wears the unread treatment — the bold title, the
    /// full-strength preview and time — which every unread row keeps,
    /// whatever its count's ink (#2292). Tests.
    var debugWearsUnreadStyle: Bool {
        titleLabel.font.fontName == UIFont.preferredFont(forTextStyle: .headline, weight: .bold).fontName
            && previewLabel.textColor == .label && timeLabel.textColor == .label
    }
}
#endif

private extension UIFont {
    static func preferredFont(forTextStyle style: TextStyle, weight: Weight) -> UIFont {
        let metrics = UIFontMetrics(forTextStyle: style)
        // The DEFAULT-size baseline: `preferredFont(forTextStyle:)` is already
        // scaled, and the metrics would scale it a second time (#482).
        let base = UIFont.systemFont(ofSize: UIFont.defaultPointSize(for: style), weight: weight)
        return metrics.scaledFont(for: base)
    }
}
