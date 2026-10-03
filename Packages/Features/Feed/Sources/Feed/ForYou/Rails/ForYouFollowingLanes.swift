import CoreGraphics
import Foundation
import PostGrid
import UIKit

/// The Following row as TWO LANES in one horizontal scroller — pictures on
/// top, words below. Began as the `-foryou-following-two-lanes` experiment
/// (#375) and was validated on 3 October 2026: it is the row now, and the
/// single lane it replaced is gone.
///
/// ```
///     Following 5 ›
///   ┌──────┐ ┌──────┐ ┌───       the top lane: MEDIA posts only, the
///   │ ▶    │ │ ▶    │ │ ▶        Following cards (`ForYouFollowingCardCell`)
///   │ Ana  │ │ Bo   │ │
///   └──────┘ └──────┘ └───
///   ┌───────────────┐ ┌────     the bottom lane: TEXT posts only, each
///   │ ◉ Cy @cy · 2h │ │ ◉ D     the list's own card (`PostGridListRowCell`)
///   │ two lines of… │ │ two     as wide as two media cards and the gap
///   │ ⎘ ⌑     💬 ♡ │ │ ⎘ ⌑     between them, two lines at most
///   └───────────────┘ └────
/// ```
///
/// **A text card is the CLASSIC card**, the one Discover's list draws: the
/// author band, the caption, and the closing line with its repost, save,
/// comments and like — the like a real stake (`PostCardStaking.bind`), not
/// the compact cards' readout. Only two things differ from the list's: its
/// caption stops at two lines with an ellipsis and no "Show more"
/// (`PostGridListRowCell.fixedCaptionLines`), and its height is the lane's,
/// what that card needs for two lines at the lane's width
/// (`textCardHeight(forWidth:)`) — a shorter caption leaves its air above the
/// closing line. It opens and closes as the list's text cards do, a window
/// with the page aligned to its caption (`ForYouRowOrigins.textCardReveal`).
///
/// **One scroll view, two rows of items.** The lanes move together because
/// they are one collection: section 0 is the top lane, section 1 the bottom
/// (`ForYouFollowingLanesLayout`). Each lane keeps the row's order (unseen
/// first, newest first) among its own posts, and fills left to right from the
/// row's margin.
///
/// **The grid is the top lane's columns, and a text card is two of them.**
/// A text card is exactly `2 × card + gap` wide and starts on an even column,
/// so every edge in the bottom lane is an edge in the top one: the two lanes
/// read as one grid, not as two strips sliding past each other.
///
/// **Where the shorter lane ends: where its posts do.** The content is as wide
/// as the longer lane, and the shorter simply stops — no post is dropped to
/// even them out (the row's "New" count would then count cards the viewer
/// cannot reach), none is moved to the other lane (a lane IS its kind), and
/// none is stretched. Unseen posts lead each lane, so what is new is at the
/// start of both, where the viewer looks first; the far end of a long lane is
/// already-seen posts. The considered alternatives, interleaving the kinds or
/// capping the longer lane at the shorter's length, both broke one of those.
///
/// **Snapping: the spread, not the column** (`snapExtents`). With text cards
/// in the row, a rest lands on a PAIR of columns — a text card's edges — with
/// the gesture choosing the edge as before (`RowEdgeSnap`): forward, a spread's
/// trailing edge on the right margin; back, its leading edge on the left. At
/// 2.3 columns per width every rest then shows two whole media cards and one
/// whole text card, each lane's neighbour peeking on the same side. Snapping
/// by single columns would leave every other rest with a text card cut in
/// half on BOTH sides of the screen — the bottom lane never at rest. The
/// start is still flush left and the end flush right (`RowEdgeSnap` adds both
/// ends). A row with no text card snaps by column, one media card at a time;
/// a row with no media card is its text cards, which are the spreads.
///
/// **A lane with nothing in it is not drawn**: no media posts, and the text
/// lane is the whole row; no text posts, and the row is the media cards alone.
enum ForYouFollowingLanes {
    /// A lane, by its section in the row's collection.
    enum Lane: Int, CaseIterable {
        /// Photos and videos — the Following cards.
        case media = 0
        /// Words alone: the list's card, two media cards wide, two lines at
        /// most.
        case text = 1

        init(_ post: GalleryPost) {
            self = post.kind == .text ? .text : .media
        }
    }

    /// The lines of words a text card in the bottom lane shows; the rest is
    /// truncated.
    static let textLines = 2

    /// Each lane's posts, in the row's order.
    static func partition(_ posts: [GalleryPost]) -> (media: [GalleryPost], text: [GalleryPost]) {
        (posts.filter { Lane($0) == .media }, posts.filter { Lane($0) == .text })
    }

    /// Where everything in the two lanes sits, in the row's CONTENT space —
    /// pure, so a suite pins it without a collection view.
    struct Geometry: Equatable {
        /// The row's visible width.
        var viewport: CGFloat
        var margin: CGFloat
        /// Between two columns, and between the two lanes.
        var gap: CGFloat
        /// A media card — a Following card.
        var cardSize: CGSize
        /// A text card's height: the list's card with two lines of caption
        /// (`textCardHeight(forWidth:)`).
        var textHeight: CGFloat
        var mediaCount: Int
        var textCount: Int

        var hasMedia: Bool { mediaCount > 0 }
        var hasText: Bool { textCount > 0 }

        /// From one column's leading edge to the next's.
        var pitch: CGFloat { cardSize.width + gap }

        /// Two columns and the gap between them.
        var textWidth: CGFloat { cardSize.width * 2 + gap }

        /// How many top-lane columns the longer lane spans.
        var columns: Int { max(mediaCount, textCount * 2) }

        func mediaFrame(at index: Int) -> CGRect {
            CGRect(
                x: margin + CGFloat(index) * pitch, y: 0,
                width: cardSize.width, height: cardSize.height
            )
        }

        /// The bottom lane's top: under the media lane and the gap, or the
        /// row's top when there is no media lane.
        var textLaneY: CGFloat { hasMedia ? cardSize.height + gap : 0 }

        func textFrame(at index: Int) -> CGRect {
            CGRect(
                x: margin + CGFloat(index * 2) * pitch, y: textLaneY,
                width: textWidth, height: textHeight
            )
        }

        var height: CGFloat {
            (hasMedia ? cardSize.height : 0)
                + (hasMedia && hasText ? gap : 0)
                + (hasText ? textHeight : 0)
        }

        var contentSize: CGSize {
            guard columns > 0 else { return CGSize(width: 0, height: height) }
            return CGSize(width: margin * 2 + CGFloat(columns) * pitch - gap, height: height)
        }

        /// What the row comes to rest on — see the note on the type: the
        /// spreads (column pairs, a text card's extent) once there is a text
        /// card, else the columns. Content space, leading to trailing.
        var snapExtents: [ClosedRange<CGFloat>] {
            guard columns > 0 else { return [] }
            guard hasText else {
                return (0..<columns).map { mediaFrame(at: $0) }.map { $0.minX...$0.maxX }
            }
            return stride(from: 0, to: columns, by: 2).map { first in
                let last = min(first + 2, columns)
                return (margin + CGFloat(first) * pitch)...(margin + CGFloat(last) * pitch - gap)
            }
        }

        /// Item `item` of lane `section`, or nil past either lane's end.
        func frame(section: Int, item: Int) -> CGRect? {
            switch Lane(rawValue: section) {
            case .media: (0..<mediaCount).contains(item) ? mediaFrame(at: item) : nil
            case .text: (0..<textCount).contains(item) ? textFrame(at: item) : nil
            case nil: nil
            }
        }
    }

    /// A text card's height in a row `width` wide: the list's card at the
    /// lane's width (two media cards and the gap) with its caption filling
    /// `textLines` lines — band, words and closing line
    /// (`PostGridListRowCell.fixedTextCardHeight`).
    @MainActor
    static func textCardHeight(forWidth width: CGFloat) -> CGFloat {
        let card = ForYouRailsView.Metrics.cardSize(forWidth: width).width
        return PostGridListRowCell.fixedTextCardHeight(
            width: card * 2 + ForYouRailsView.Metrics.itemGap, captionLines: textLines
        )
    }

    /// The row's geometry at `width`, with the Following card's size, margin
    /// and gap.
    @MainActor
    static func geometry(forWidth width: CGFloat, mediaCount: Int, textCount: Int) -> Geometry {
        typealias Metrics = ForYouRailsView.Metrics
        return Geometry(
            viewport: width,
            margin: Metrics.sideMargin,
            gap: Metrics.itemGap,
            cardSize: Metrics.cardSize(forWidth: width),
            // Measured only when there is a text card to size.
            textHeight: textCount > 0 ? textCardHeight(forWidth: width) : 0,
            mediaCount: mediaCount,
            textCount: textCount
        )
    }
}

/// The two lanes' layout: section 0 along the top, section 1 below it, one
/// content width — see `ForYouFollowingLanes`.
@MainActor
final class ForYouFollowingLanesLayout: UICollectionViewLayout {
    private(set) var geometry = ForYouFollowingLanes.geometry(forWidth: 0, mediaCount: 0, textCount: 0)
    private var attributes: [IndexPath: UICollectionViewLayoutAttributes] = [:]

    override func prepare() {
        super.prepare()
        guard let collectionView else { return }
        let sections = collectionView.numberOfSections
        func count(_ lane: ForYouFollowingLanes.Lane) -> Int {
            lane.rawValue < sections ? collectionView.numberOfItems(inSection: lane.rawValue) : 0
        }
        geometry = ForYouFollowingLanes.geometry(
            forWidth: collectionView.bounds.width,
            mediaCount: count(.media), textCount: count(.text)
        )
        attributes = [:]
        for lane in ForYouFollowingLanes.Lane.allCases {
            for item in 0..<count(lane) {
                let indexPath = IndexPath(item: item, section: lane.rawValue)
                guard let frame = geometry.frame(section: lane.rawValue, item: item) else { continue }
                let attribute = UICollectionViewLayoutAttributes(forCellWith: indexPath)
                attribute.frame = frame
                attributes[indexPath] = attribute
            }
        }
    }

    override var collectionViewContentSize: CGSize { geometry.contentSize }

    override func layoutAttributesForElements(in rect: CGRect) -> [UICollectionViewLayoutAttributes]? {
        attributes.values.filter { $0.frame.intersects(rect) }
    }

    override func layoutAttributesForItem(at indexPath: IndexPath) -> UICollectionViewLayoutAttributes? {
        attributes[indexPath]
    }

    /// A new WIDTH re-sizes every card; a scroll moves none of them.
    override func shouldInvalidateLayout(forBoundsChange newBounds: CGRect) -> Bool {
        newBounds.size != collectionView?.bounds.size
    }
}
