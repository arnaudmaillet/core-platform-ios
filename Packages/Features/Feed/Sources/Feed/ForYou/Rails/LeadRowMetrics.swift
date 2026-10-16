import DesignSystem
import PostGrid
import UIKit

/// The sizes every horizontal row leading a grid page shares (#1271): For
/// You's Friends faces, a shelf's media and text cards (`PostShelfSection`),
/// and the rows other screens borrow them for.
///
/// **Every row rests on an item's edge, the gesture picking the edge**
/// (2026-09-29, `ForYouRowSnap`). Hence the sizes: a gap no narrower than the
/// margin, so the side a snap empties is empty, and items sized from the
/// width (`itemWidth`) so the other side always crops one — the faces
/// included, which are no longer a fixed size.
@MainActor
enum LeadRowMetrics {
    static var sideMargin: CGFloat { PostGridListLayout.sideMargin }
    /// Between two items of a row, in both rows — and NO LESS THAN THE
    /// SIDE MARGIN, which is what lets a snap hide a side entirely: an item
    /// flush with one margin leaves its neighbour `itemGap - sideMargin`
    /// points off that edge of the screen (`ForYouRowSnap`). Any tighter
    /// and a sliver of the item the snap put away stays on screen.
    static var itemGap: CGFloat { sideMargin }
    /// Cards per screen width, counted from the left margin: two whole,
    /// and a third peeking to say the row goes on.
    static let cardsPerWidth: CGFloat = 2.3
    /// Faces per screen width, the same way: four whole and a fifth
    /// cropped by the right edge — on every width, which is why the face
    /// is sized from the width rather than fixed (at this gap, no one size
    /// leaves a crop on 375, 402 and 440 alike).
    static let storiesPerWidth: CGFloat = 4.4
    /// Height over width: portrait, tall enough that two lines of caption
    /// sit over the picture without burying it.
    static let cardAspect: CGFloat = 4.0 / 3.0
    /// Between the two rows, and between the last row and "For you": the
    /// app's ONE section gap (`Spacing.section`, 2026-09-30), from a row's
    /// foot to the next title's line — the bar's own air counted in
    /// (`SectionTitleView.gapAbove`). The sound sheet and the pushed
    /// Following / Friends lists keep the same distance.
    static var rowGap: CGFloat { SectionTitleView.gapAbove() }
    /// Below "For you", before the list's first card: what
    /// `Spacing.sectionTitle` asks beyond the bar's own air — none at the
    /// default size — so "For you" stands over the list as far as
    /// "Friends" and "Following" over their rows.
    static var listGap: CGFloat { SectionTitleView.gapBelow() }

    /// The width of one item when `perWidth` of them — gaps included —
    /// fill `width` from the left margin: `perWidth.rounded(.down)` whole
    /// items, the rest of one cropped by the screen's right edge. The
    /// mirror holds at the far end, flush right with one cropped on the
    /// left, since the gaps and margins are the same on both sides.
    ///
    /// Whole points, so every item's edges — and every offset a snap
    /// computes from them — fall on the pixel grid.
    static func itemWidth(forWidth width: CGFloat, perWidth: CGFloat) -> CGFloat {
        ForYouRowSnap.itemWidth(forWidth: width, perWidth: perWidth, margin: sideMargin, gap: itemGap)
    }

    static func cardSize(forWidth width: CGFloat) -> CGSize {
        let cardWidth = itemWidth(forWidth: width, perWidth: cardsPerWidth)
        return CGSize(width: cardWidth, height: (cardWidth * cardAspect).rounded())
    }

    /// A story cell at `width`: the disc (face and ring), and the name
    /// under it no wider than the disc.
    static func storySize(forWidth width: CGFloat) -> CGSize {
        ForYouStoryCell.Metrics.size(discSide: itemWidth(forWidth: width, perWidth: storiesPerWidth))
    }
}
