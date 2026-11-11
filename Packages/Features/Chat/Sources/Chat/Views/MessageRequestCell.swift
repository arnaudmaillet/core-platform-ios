import CoreModels
import DesignSystem
import EmoteKit
import MediaCore
import UIKit

/// A pending message request, laid out as a standard two-line messaging row
/// with its decision attached (#2088):
///
///     [face+mark] [name · time ·············]
///                 [message preview ·········] ⟷ [Accept] ✕
///
/// The face wears the relation mark, as an All row's does (#2049): the "+"
/// follows — it never accepts — and the rest of the row behaves as before.
/// Accept and a bare ✕ are one line on the row's midline, the face's (the
/// owner, 2026-11-07, #2171): no count — a new request reads as new by its
/// bold preview, and the tab's badge counts requests, not their messages.
/// The text column takes whatever width is left, which is what makes the
/// gap before the buttons elastic. The timestamp sits directly beside the
/// name as part of the same phrase rather than anchored to the far edge —
/// with a short name, a lone right-aligned time reads as unrelated to it.
/// Name and preview truncate; the timestamp and the buttons never shrink, so
/// a long name eats into its own line rather than pushing the decision off
/// screen or displacing the time.
///
/// Accept and dismiss are in-cell buttons rather than swipe actions because
/// the horizontal axis belongs to paging between inbox categories — and
/// because a request is a decision, which reads better as a visible pair of
/// choices than as a hidden gesture. Accept leads as the primary call to
/// action; dismissal is deliberately quieter than the thing it undoes.
final class MessageRequestCell: UITableViewCell {
    static let reuseIdentifier = "MessageRequestCell"

    var onAccept: (() -> Void)?
    var onDismiss: (() -> Void)?

    /// The face, wearing the relation mark (#2088), as an All row's.
    private let avatarView = RelationMarkedAvatarView()
    /// A group's invitation wears the group's picture over the face's place
    /// (#2233), as its row will once accepted.
    private let groupAvatar = GroupAvatarView()
    private var avatarTask: Task<Void, Never>?
    /// Guards a late fetch against cell reuse — see `ConversationCell`.
    private var avatarPeerID: ProfileID?
    private let nameLabel = UILabel()
    private let previewLabel = EmoteLabel()
    private let timeLabel = UILabel()
    /// The app's button, shared with every person row (#932), with its one
    /// press (#866): the row action (#2231), repeated on every request, so
    /// on the tinted ground rather than a solid capsule.
    private let acceptButton = AppButton(aspect: .rowAction, size: .row, content: .title("Accept"))
    /// A bare glyph, the Suggestions row's ✕ (#2088): quiet enough that the
    /// eye lands on Accept. Its hit region stays 44×44
    /// (`AppControl.hitRegion`).
    private let dismissButton: AppIconButton = {
        let button = AppIconButton(style: .glyph, content: .symbol("xmark"))
        button.inkColor = .tertiaryLabel
        return button
    }()

    /// The peer the row shows, for the relations' updates.
    private(set) var peerID: ProfileID?

    /// Accept. Internal for tests.
    var debugAcceptButton: AppButton { acceptButton }
    /// Decline. Internal for tests.
    var debugDismissButton: AppIconButton { dismissButton }
    /// The face. Internal for tests.
    var debugFace: UIView { avatarView }
    /// The face's badge. Internal for tests.
    var debugBadge: RelationBadgeView { avatarView.badge }
    /// The mark on show. Internal for tests.
    var relationMark: PersonPill.Badge { avatarView.mark }
    /// The group's picture, on an invitation (#2233). Internal for tests.
    var debugGroupAvatar: GroupAvatarView? { groupAvatar.isHidden ? nil : groupAvatar }

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        configure()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func prepareForReuse() {
        super.prepareForReuse()
        onAccept = nil
        onDismiss = nil
        avatarTask?.cancel()
        avatarTask = nil
        avatarPeerID = nil
        peerID = nil
        avatarView.setPicture(nil, pipeline: nil)
        groupAvatar.setContent(nil, pipeline: nil)
        // A reused row starts unknown for its next person, never wearing
        // the previous one's mark (#2098).
        avatarView.setMark(.loading, animated: false)
        avatarView.onFollowTapped = nil
    }

    /// Same contract as `ConversationCell`: the row is complete on initials,
    /// and the picture streams in behind it if `profile.v1` has one.
    ///
    /// `mark` and `onFollow`: the face's relation and its "+" (#2088), as an
    /// All row's — `.none` for a relation not known yet, or a host with no
    /// graph.
    func configure(
        with model: ConversationDisplayModel,
        imagePipeline: ImagePipeline? = nil,
        avatars: (any PeerAvatarProviding)? = nil,
        mark: PersonPill.Badge = .none,
        onFollow: (() -> Void)? = nil
    ) {
        peerID = model.peerID
        avatarView.setMonogram(model.monogram)
        avatarView.setMark(model.peerID == nil ? .none : mark, animated: false)
        avatarView.onFollowTapped = onFollow
        let isGroup = model.groupAvatar != nil
        groupAvatar.setContent(model.groupAvatar, pipeline: imagePipeline)
        groupAvatar.isHidden = !isGroup
        avatarView.alpha = isGroup ? 0 : 1
        if isGroup {
            avatarTask?.cancel()
            avatarTask = nil
            avatarPeerID = nil
            avatarView.setPicture(nil, pipeline: nil)
        } else {
            loadAvatar(for: model, imagePipeline: imagePipeline, avatars: avatars)
        }
        applyUnreadStyle(model.isUnread)
        nameLabel.text = model.title
        previewLabel.text = Self.previewText(for: model)
        // The separator belongs to the timestamp, so a conversation with no
        // activity collapses the whole thing rather than leaving a stray dot.
        timeLabel.text = Self.timestampText(for: model)
        timeLabel.isHidden = timeLabel.text == nil
        // A group's invitation (#2214) is the same decision, about a group.
        acceptButton.accessibilityLabel = model.invitation == nil
            ? "Accept request from \(model.title)" : "Accept invitation to \(model.title)"
        dismissButton.accessibilityLabel = model.invitation == nil
            ? "Decline request from \(model.title)" : "Decline invitation to \(model.title)"
        // The row itself reads as one sentence; the two buttons stay separate
        // elements so VoiceOver can reach each decision.
        accessibilityElements = [contentView, acceptButton, dismissButton]
        contentView.isAccessibilityElement = true
        // "New request", never a message count: the row shows none (#2171).
        contentView.accessibilityLabel = [
            model.title, model.isUnread ? Self.newWords : nil, model.timeText, Self.previewText(for: model)
        ].compactMap(\.self).filter { !$0.isEmpty }.joined(separator: ", ")
        updateFollowAccessibility()
    }

    /// The face's relation, changed on screen.
    func setRelationMark(_ mark: PersonPill.Badge, animated: Bool) {
        avatarView.setMark(mark, animated: animated)
        updateFollowAccessibility()
    }

    /// VoiceOver's way to the "+": a "Follow" action on the row while the
    /// face shows it, and the mark's state otherwise read by the badge.
    private func updateFollowAccessibility() {
        guard avatarView.mark == .follow, let follow = avatarView.onFollowTapped else {
            contentView.accessibilityCustomActions = nil
            return
        }
        contentView.accessibilityCustomActions = [UIAccessibilityCustomAction(name: "Follow") { _ in
            follow()
            return true
        }]
    }

    /// ⚠️ THE "+" IS ASKED FIRST, as on an All row: its touch area reaches
    /// past the 48 pt disc and the stack round it, which would refuse the
    /// touch before the badge saw it.
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        if let badge = avatarView.tappableBadge, !isHidden, alpha > 0.01,
           badge.point(inside: convert(point, to: badge), with: event) {
            return badge
        }
        return super.hitTest(point, with: event)
    }

    /// What VoiceOver says of a request the viewer has not opened yet.
    static let newWords = "New request"

    /// A request usually *is* its first message, so the preview carries the
    /// decision. When there is nothing to show, say what the row is rather
    /// than leaving a blank line.
    ///
    /// A group's invitation (#2214) says who invited the viewer, and to what.
    static func previewText(for model: ConversationDisplayModel) -> String {
        if let invitation = model.invitation { return invitation }
        return model.preview.isEmpty ? "Wants to send you a message" : model.previewLine
    }

    /// The timestamp as it reads beside the name — "· 12m". `nil` when the
    /// conversation has no activity to date, so nothing is rendered at all.
    static func timestampText(for model: ConversationDisplayModel) -> String? {
        model.timeText.isEmpty ? nil : "· \(model.timeText)"
    }

    /// An unread request carries its preview in full strength and weight — the
    /// same treatment an unread conversation gets in the All list, because it is
    /// the same statement. Only the font and colour change, so a row settling
    /// from unread to read cannot move the rows around it.
    private func applyUnreadStyle(_ isUnread: Bool) {
        let plain = UIFont.appFont(forTextStyle: .subheadline)
        previewLabel.font = isUnread
            ? UIFont.systemFont(ofSize: plain.pointSize, weight: .semibold)
            : plain
        previewLabel.textColor = isUnread ? .label : .secondaryLabel
    }

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

        // An invitation's group photo is already a URL (#2214): no lookup.
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

    private func configure() {
        // No disclosure chevron: the row's affordances are the two buttons,
        // and a third trailing glyph would crowd them.
        selectionStyle = .default

        nameLabel.font = .appFont(forTextStyle: .headline)
        nameLabel.textColor = .label

        previewLabel.font = .appFont(forTextStyle: .subheadline)
        previewLabel.textColor = .secondaryLabel

        timeLabel.font = .appFont(forTextStyle: .footnote)
        timeLabel.textColor = .secondaryLabel

        for label in [nameLabel, previewLabel, timeLabel] {
            label.adjustsFontForContentSizeCategory = true
            // One line each: the row is a fixed two-line silhouette, so every
            // request has the same height however long its message is.
            label.numberOfLines = 1
            label.lineBreakMode = .byTruncatingTail
        }
        // The text is what gives way. Both labels yield before the timestamp
        // or the buttons do, so long names truncate instead of shoving the
        // decision out of reach.
        for label in [nameLabel, previewLabel] {
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            label.setContentHuggingPriority(.defaultLow, for: .horizontal)
        }
        timeLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        timeLabel.setContentHuggingPriority(.required, for: .horizontal)

        configureAcceptButton()
        configureDismissButton()

        // Name and timestamp read as one phrase, so they sit together at a
        // small fixed gap. Baseline-aligned, so the smaller timestamp sits on
        // the name's line rather than against its cap height.
        let namePair = UIStackView(arrangedSubviews: [nameLabel, timeLabel])
        namePair.axis = .horizontal
        namePair.alignment = .firstBaseline
        namePair.spacing = Spacing.xs
        namePair.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        // The spacer — not the name — absorbs the leftover width, which is
        // what keeps the pair adjacent instead of stretched to the column's
        // edges. It is a sibling of the baseline-aligned pair rather than a
        // member of it: a plain view has no baseline to align to.
        let titleSpacer = UIView()
        titleSpacer.setContentHuggingPriority(.defaultLow - 1, for: .horizontal)
        titleSpacer.setContentCompressionResistancePriority(.defaultLow - 1, for: .horizontal)
        let titleRow = UIStackView(arrangedSubviews: [namePair, titleSpacer])
        titleRow.axis = .horizontal
        titleRow.alignment = .fill

        let textColumn = UIStackView(arrangedSubviews: [titleRow, previewLabel])
        textColumn.axis = .vertical
        textColumn.spacing = 2
        // Low hugging: the text column absorbs all leftover width, which IS
        // the elastic gap between the preview and the buttons.
        textColumn.setContentHuggingPriority(.defaultLow, for: .horizontal)
        textColumn.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let actions = UIStackView(arrangedSubviews: [acceptButton, dismissButton])
        actions.axis = .horizontal
        actions.spacing = Spacing.sm
        actions.alignment = .center
        actions.setContentHuggingPriority(.required, for: .horizontal)
        actions.setContentCompressionResistancePriority(.required, for: .horizontal)

        let row = UIStackView(arrangedSubviews: [avatarView, textColumn, actions])
        row.axis = .horizontal
        // Centred: the face, Accept and the ✕ sit on the row's midline.
        row.alignment = .center
        row.spacing = Spacing.md
        // Tallest of the three things in the row: the disc, the two lines of
        // type, and Accept. At the default text size the two lines decide the
        // shared pitch, as on every person row; at larger sizes the row grows
        // with the text.
        let inset = PersonRowMetrics.verticalInset(forContentHeight: max(
            MonogramAvatarView.rowDiameter,
            PersonRowMetrics.textHeight([.headline, .subheadline]),
            Self.actionColumnHeight(accept: acceptButton)
        ))
        row.pin(to: contentView, insets: NSDirectionalEdgeInsets(
            top: inset, leading: Spacing.lg, bottom: inset, trailing: Spacing.lg
        ))
        groupAvatar.isHidden = true
        // The row reads as one sentence: it says the group's name.
        groupAvatar.isAccessibilityElement = false
        groupAvatar.constrain(in: contentView) { _ in
            groupAvatar.leadingAnchor.constraint(equalTo: avatarView.leadingAnchor)
            groupAvatar.trailingAnchor.constraint(equalTo: avatarView.trailingAnchor)
            groupAvatar.topAnchor.constraint(equalTo: avatarView.topAnchor)
            groupAvatar.bottomAnchor.constraint(equalTo: avatarView.bottomAnchor)
        }
    }

    /// Primary call to action: a filled accent pill. It carries a word rather
    /// than a glyph because accepting a stranger's message is a decision worth
    /// naming.
    private func configureAcceptButton() {
        acceptButton.addAction(UIAction { [weak self] _ in self?.onAccept?() }, for: .primaryActionTriggered)
        acceptButton.setContentHuggingPriority(.required, for: .horizontal)
        acceptButton.setContentCompressionResistancePriority(.required, for: .horizontal)
    }

    /// Secondary: a bare glyph, the Suggestions row's ✕ (#2088). Quiet
    /// enough that the eye lands on Accept first; its hit region stays 44×44
    /// (`AppControl.hitRegion`), so the smaller glyph is as easy to tap.
    private func configureDismissButton() {
        dismissButton.addAction(UIAction { [weak self] _ in self?.onDismiss?() }, for: .primaryActionTriggered)
        dismissButton.setContentHuggingPriority(.required, for: .horizontal)
        dismissButton.setContentCompressionResistancePriority(.required, for: .horizontal)
    }

    /// The actions' height: Accept's, the taller of the pair.
    static func actionColumnHeight(accept: UIView) -> CGFloat {
        accept.systemLayoutSizeFitting(UIView.layoutFittingCompressedSize).height
    }
}
