import CoreModels
import DesignSystem
import MediaCore
import UIKit

/// A conversation row in the inbox's search results.
///
/// ⚠️ **The same row as the inbox list**, via `ConversationRowView`.
///
/// It used to be deliberately different — a `UIListContentConfiguration` with the
/// time as a trailing accessory, its own avatar host, and pin and mute dropped on
/// the argument that a list the viewer filtered themselves is already ordered by
/// their query. That reasoning was sound and the result still read as a second
/// design: different fonts reached by a different route, a different row height,
/// a different avatar class, and management state that existed on one surface
/// only. Parity across the screen was chosen over the argument.
///
/// The pinned BAND does not come with it: that is the table cell's
/// `backgroundView`, and a list cell has no equivalent that spans its accessory
/// strip. The pin glyph does, which is what names the state up close.
final class ConversationResultCell: UICollectionViewListCell {
    private let rowView = ConversationRowView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        rowView.pin(to: contentView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func prepareForReuse() {
        super.prepareForReuse()
        rowView.prepareForReuse()
        peerID = nil
    }

    /// The peer this cell shows, for a relation that changes (#2049).
    private(set) var peerID: ProfileID?

    /// Same contract as the inbox rows: initials now, picture when it lands,
    /// and the face's relation mark with its "+" (#2049).
    func configure(
        with model: ConversationDisplayModel,
        imagePipeline: ImagePipeline? = nil,
        avatars: (any PeerAvatarProviding)? = nil,
        mark: PersonPill.Badge = .none,
        onFollow: (() -> Void)? = nil
    ) {
        peerID = model.peerID
        accessibilityLabel = rowView.configure(
            with: model, imagePipeline: imagePipeline, avatars: avatars, mark: mark
        )
        rowView.onFollowTapped = onFollow
        // ⚠️ No accessories. The row draws its own time and glyphs in its
        // trailing column now, and a list cell's accessories sit OUTSIDE
        // `contentView` — leaving one here would put a second time label beside
        // the row's own and shorten the content by its width.
        accessories = []
    }

    /// VoiceOver's actions: the system's own (a table's swipe actions) and,
    /// while the face shows the "+", "Follow" (#2049) — added, never in
    /// their place.
    override var accessibilityCustomActions: [UIAccessibilityCustomAction]? {
        get {
            let actions = (super.accessibilityCustomActions ?? []) + (rowView.followAccessibilityActions ?? [])
            return actions.isEmpty ? nil : actions
        }
        set { super.accessibilityCustomActions = newValue }
    }

    /// The face's relation, changed on screen (#2049).
    func setRelationMark(_ mark: PersonPill.Badge, animated: Bool) {
        rowView.setRelationMark(mark, animated: animated)
    }
}
