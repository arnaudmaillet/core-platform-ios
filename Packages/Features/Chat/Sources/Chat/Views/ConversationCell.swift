import CoreModels
import DesignSystem
import MediaCore
import UIKit

/// A conversation in the inbox list.
///
/// The row itself is `ConversationRowView`, shared with the search results so
/// the two cannot drift. What lives here is the one thing a table cell has and a
/// list cell does not: the pinned band.
final class ConversationCell: UITableViewCell {
    static let reuseIdentifier = "ConversationCell"

    /// The pinned band, as the cell's `backgroundView`.
    ///
    /// ⚠️ **Not `contentView.backgroundColor`, and not the cell's own.** Tinting
    /// the content view left an untinted strip down the row's trailing edge
    /// wherever an accessory sat outside it — the disclosure chevron did that
    /// until it was removed as redundant, and any future accessory would too. The
    /// cell's own `backgroundColor` is re-applied by UIKit during batch layout,
    /// which is what made the band vanish mid-move.
    ///
    /// `backgroundView` is neither: it spans the cell's full bounds, sits behind
    /// both the content and any accessory, and survives the move.
    private let pinnedBackground = UIView()
    private let rowView = ConversationRowView()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        // Installed once and recoloured thereafter — swapping the view per
        // configure would hand the move animation a different layer halfway
        // through.
        backgroundView = pinnedBackground
        rowView.pin(to: contentView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func prepareForReuse() {
        super.prepareForReuse()
        rowView.prepareForReuse()
    }

    func configure(
        with model: ConversationDisplayModel,
        imagePipeline: ImagePipeline? = nil,
        avatars: (any PeerAvatarProviding)? = nil
    ) {
        accessibilityLabel = rowView.configure(
            with: model, imagePipeline: imagePipeline, avatars: avatars
        )
        // Pinned reads twice, at two distances: a translucent band that
        // separates the pinned block at a glance (Telegram idiom; system fill
        // colors are translucent and adapt to dark mode), and a pin glyph under
        // the timestamp that names the state up close.
        //
        // ⚠️ Unanimated. This used to cross-fade, which meant a cell dequeued at
        // the pinned row's DESTINATION spent the first quarter-second fading its
        // band in — the row arrived wearing its glyph and no tint, which is the
        // tail end of the lag this whole thread chased. The move animation is
        // what carries the change now; the colour is simply true on every frame
        // the row is drawn.
        applyPinnedTint(model.isPinned, animated: false)
    }

    /// Paints the pinned state on THIS cell, right now.
    ///
    /// ⚠️ **Called at the action site, before the snapshot that moves the row.**
    /// Pinning changes content and position together, and every attempt to let
    /// the data source carry the content half lost the race: a reconfigure in
    /// the same snapshot as the move settles at the END of the move, and a
    /// separate `apply` in the same runloop turn gets coalesced with it —
    /// especially under the context menu's own dismissal animation, which is
    /// where pinning is actually triggered from. Mutating the visible cell is
    /// the only path that puts the band on frame 0.
    ///
    /// The later reconfigure then sets the same values and does nothing, so this
    /// does not fight the data source; it front-runs it.
    func setPinnedStyle(_ isPinned: Bool, animated: Bool) {
        rowView.setPinnedIconHidden(!isPinned)
        applyPinnedTint(isPinned, animated: animated)
        layoutIfNeeded()
    }

    /// The pinned band. Cross-faded rather than swapped when the row is already
    /// on screen, so the tint reads as part of the same gesture. Set outright
    /// otherwise (first render, reuse during a scroll), where an animation would
    /// be a flash on a row the viewer never saw unpinned.
    private func applyPinnedTint(_ isPinned: Bool, animated: Bool = true) {
        let tint: UIColor? = isPinned ? .quaternarySystemFill : nil
        guard animated, window != nil, pinnedBackground.backgroundColor != tint else {
            pinnedBackground.backgroundColor = tint
            return
        }
        UIView.transition(
            with: pinnedBackground, duration: 0.25,
            options: [.transitionCrossDissolve, .allowUserInteraction]
        ) { self.pinnedBackground.backgroundColor = tint }
    }
}
