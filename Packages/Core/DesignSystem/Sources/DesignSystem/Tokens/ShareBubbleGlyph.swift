import UIKit

/// Share alone in a round bubble beside the like pill (#2581): the action
/// column's Share (`SnapSoundBubbleButton`, both layouts) and the composer's
/// slot (`CommentsInputBar`). The glyph is the owner's send
/// (`PostActionSymbol.share`, #2416); a bar item, a menu row or a line of
/// text draws it as it is.
///
/// ⚠️ THE SIZE IS SET ON THE DRAWN INK, NOT THE POINT SIZE. The like pill's
/// heart is 15 pt semibold, but a `UIButton.Configuration` draws a symbol
/// whose configuration names no scale at `.large`: the heart stands 20.7 ×
/// 17.7 pt on screen, the size the owner measured. The bubble's Share is a
/// plain image view, so at the composer's old 17 pt it stood 16.3 pt square,
/// about a quarter narrower. At `pointSize` the plane paints the heart's ink
/// (area and box, within `AppSymbolSizeTests`' 8 %). Its configuration names
/// `.medium`, so the composer's slot, a configured button too, draws it at
/// that size instead of scaling it again.
///
/// ⚠️ CENTRED BY ITS INK'S CENTRE OF MASS, NOT ITS BOX. The plane carries its
/// weight in its top-right point, so a plane whose box is centred reads high
/// and to the right (1.1 pt each way at `pointSize`). `offset(pointSize:)`
/// moves it back. Not in the symbol itself: a symbol image is as tall as its
/// ink, so a lower glyph in the template only moves its baseline, never its
/// place in a bubble; and the horizontal share is past the set's 4-unit side
/// margin (measured on the compiled catalogue, #2581).
public enum ShareBubbleGlyph {
    /// The point size whose drawn ink matches the like pill's heart.
    public static let pointSize: CGFloat = 19

    /// The glyph's configuration in a bubble: `pointSize`, semibold like every
    /// glyph in the column, at the `.medium` scale whoever draws it.
    public static let configuration = UIImage.SymbolConfiguration(pointSize: pointSize, weight: .semibold)
        .applying(UIImage.SymbolConfiguration(scale: .medium))

    /// The glyph as a bubble draws it, a template image.
    public static func image() -> UIImage? {
        UIImage.symbol(named: PostActionSymbol.share, configuration: configuration)
    }

    /// How far the ink's centre of mass sits from the image's centre, per
    /// point of size: right (+x) and up (−y) of it.
    static let massOffsetPerPoint = UIOffset(horizontal: 0.058, vertical: -0.058)

    /// The move from a bubble's centre to the image's centre that puts the
    /// ink's centre of mass on the bubble's centre: down and to the left.
    public static func offset(pointSize: CGFloat = ShareBubbleGlyph.pointSize) -> UIOffset {
        UIOffset(
            horizontal: -massOffsetPerPoint.horizontal * pointSize, vertical: -massOffsetPerPoint.vertical * pointSize
        )
    }

    /// `insets` for a button that centres `image` (`UIButton.Configuration`),
    /// grown on one side per axis so the image's centre stands `offset()` off
    /// the button's. Such a button centres the image's alignment rectangle,
    /// not the image, so that difference is taken off the move. The plane
    /// never mirrors, so its left is the left in a right-to-left layout too,
    /// where it is the trailing side.
    public static func contentInsets(
        _ insets: NSDirectionalEdgeInsets, for image: UIImage, direction: UIUserInterfaceLayoutDirection
    ) -> NSDirectionalEdgeInsets {
        let alignment = image.alignmentRectInsets
        let placed = UIOffset(
            horizontal: (alignment.right - alignment.left) / 2, vertical: (alignment.bottom - alignment.top) / 2
        )
        let move = UIOffset(
            horizontal: offset().horizontal - placed.horizontal, vertical: offset().vertical - placed.vertical
        )
        let towardTrailing = direction == .leftToRight ? move.horizontal : -move.horizontal
        var moved = insets
        moved.top += max(0, 2 * move.vertical)
        moved.bottom += max(0, -2 * move.vertical)
        moved.leading += max(0, 2 * towardTrailing)
        moved.trailing += max(0, -2 * towardTrailing)
        return moved
    }
}
