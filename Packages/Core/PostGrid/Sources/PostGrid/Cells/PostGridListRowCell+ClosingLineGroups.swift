import DesignSystem
import UIKit

// The closing line's two groups (#2441, the owner 2026-11-14)
//
//     ☆  ⇄  ↗                                   💬 78      ♥ 234
//
// * **Left, the actions with no count**: save, repost, share, in that order
//   (from me outward: for me, to my followers, to anyone). Icons only, close
//   together: each a 44 × 44 pt target (`AppControl.hitRegion`), the glyphs
//   `leadingGlyphPitch` apart centre to centre, the first glyph's ink on the
//   line's column (`closingLineHang`).
// * **Right, the actions with a count**: comments, then the like under the
//   thumb, each in a slot of ONE fixed width on the trailing margin, the glyph
//   on the slot's leading edge and the count after it. The slot is as wide as
//   the widest count the app writes ("999K"), so the bubble and the heart
//   stand at the same x on every post whatever their counts, and the list
//   reads in columns.
//
// Repost is drawn only once something publishes one (#801): until then the
// left group is `☆ ↗` (`onRepostTapped` nil).
extension PostGridListRowCell {
    /// Centre to centre between two glyphs of the left group (the issue's
    /// 40–42 pt).
    public static let leadingGlyphPitch: CGFloat = 41

    /// The left group's box: the pitch less the line's gap, the glyph centred
    /// in it (`PostCardAction.inkLeading` reads the box).
    static var leadingGlyphBox: CGFloat { leadingGlyphPitch - chipGap }

    /// Names the count slots' width constraint, so a text size change finds it.
    private static let countSlotID = "PostGridListRowCell.countSlot"

    /// Fixes the two groups' widths, once, from `buildRowChrome`.
    func buildClosingLineGroups() {
        for button in [bookmarkAction, repostAction, shareAction] {
            PostCardAction.fixBox(button, width: Self.leadingGlyphBox)
        }
        for button in [commentsAction, likesAction] {
            button.contentHorizontalAlignment = .leading
            button.setContentHuggingPriority(.defaultLow, for: .horizontal)
            let slot = button.widthAnchor.constraint(equalToConstant: 0)
            // Below required, and below a count's own 999: on a card too narrow
            // for both groups the SLOTS narrow first, and a count never clips.
            slot.priority = .defaultHigh
            slot.identifier = Self.countSlotID
            slot.isActive = true
        }
        sizeCountSlots()
        // The slots grow with their widest count; the left group keeps its targets.
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) {
            (cell: PostGridListRowCell, _: UITraitCollection) in
            cell.sizeCountSlots()
        }
    }

    /// The width of a count's slot at the text size now: the widest count the
    /// app writes ("999K", `CountFormatter`) beside the wider of the two glyphs.
    public var countSlotWidth: CGFloat {
        let widest = 999_000
        return max(
            commentsAction.fittingSize(for: .init(symbol: ActionSymbol.comments, count: widest)).width,
            likesAction.fittingSize(for: .init(symbol: ActionSymbol.like, count: widest)).width
        )
    }

    private func sizeCountSlots() {
        let width = countSlotWidth
        for button in [commentsAction, likesAction] {
            button.constraints.first { $0.identifier == Self.countSlotID }?.constant = width
        }
    }

    /// What a share sheet raised from the row's share points at.
    public var shareAnchor: UIView { shareAction }

    /// Whether the row draws its own share (#2441): its post's menu then
    /// offers none (`PostMenuRows.offersShare`).
    public var drawsShare: Bool { !shareAction.isHidden }

    /// The closing line's controls, left to right as drawn: their labels and
    /// frames in the cell. For a test, and for a stand-in's comparison.
    public var closingLineControls: [(label: String, frame: CGRect)] {
        metaRow.arrangedSubviews
            .compactMap { $0 as? AppIconButton }
            .filter { !$0.isHidden }
            .map { ($0.accessibilityLabel ?? "", $0.convert($0.bounds, to: self)) }
    }

    #if DEBUG
    /// The left group's controls, drawn or not. Tests.
    var debugLeftGroup: [AppIconButton] { [bookmarkAction, repostAction, shareAction].filter { !$0.isHidden } }
    /// The two count slots, comments then the like. Tests.
    var debugCountSlots: [AppIconButton] { [commentsAction, likesAction] }
    #endif
}
