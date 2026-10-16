import CoreModels
import DesignSystem
import UIKit

/// What every horizontal row of the lead (the Friends faces, a shelf's media
/// and text cards) does on a release: it comes to rest on an item's edge, the
/// side picked by the gesture's direction (`ForYouRowSnap`, 2026-09-29).
///
/// One per owner of rows, fed by that owner's scroll delegate: it keeps the
/// row under the finger and which way it last moved — what a release with no
/// speed left snaps by.
@MainActor
final class RowSnapper {
    /// The row under the finger and its tracker. Nil between drags.
    private var drag: (row: UIScrollView, tracker: ForYouRowDragTracker)?

    func willBeginDragging(_ row: UIScrollView) {
        drag = (row, ForYouRowDragTracker(offset: row.contentOffset.x))
    }

    func didScroll(_ row: UIScrollView) {
        if let drag, drag.row === row {
            self.drag?.tracker.track(row.contentOffset.x)
        }
    }

    /// ⚠️ A RELEASE WITH NO SPEED IS ANIMATED BY HAND. Handed a new target
    /// with a zero velocity, UIScrollView jumps to it rather than gliding, so
    /// a slow drag lifted from a standstill would teleport the row. There the
    /// row is told to stay where it is and is then animated to the snap.
    ///
    /// - Parameter stepped: the row moves ONE item per gesture (the text
    ///   cards, four fifths of the screen wide) rather than where the
    ///   projection carries it.
    func willEndDragging(
        _ row: UICollectionView,
        velocity: CGPoint,
        targetContentOffset: UnsafeMutablePointer<CGPoint>,
        stepped: Bool
    ) {
        let tracker = drag?.row === row ? drag?.tracker : nil
        drag = nil
        let target = Self.snapTarget(
            in: row,
            projected: targetContentOffset.pointee.x,
            start: tracker?.start ?? row.contentOffset.x,
            direction: ForYouRowSnap.direction(velocity: velocity.x, lastMovement: tracker?.lastMovement),
            stepped: stepped
        )
        let offsets = Self.offsetRange(of: row)
        let current = row.contentOffset.x
        guard abs(velocity.x) < ForYouRowSnap.flickVelocity, offsets.contains(current) else {
            // Moving — or pulled past an end, where UIKit's own spring back is
            // the motion wanted: the deceleration is bent onto the snap.
            targetContentOffset.pointee.x = target
            return
        }
        targetContentOffset.pointee.x = current
        guard target != current else { return }
        DispatchQueue.main.async { [weak row] in
            guard let row, !row.isTracking else { return }
            row.setContentOffset(CGPoint(x: target, y: row.contentOffset.y), animated: true)
        }
    }

    /// Where `row` rests after a release — its items' extents, read from its
    /// layout, handed to `ForYouRowSnap`.
    ///
    /// **A stepped row moves ONE CARD per gesture** (`steppedTarget`, the card
    /// carousel's variant): a fling the projection carried past two or three
    /// wide cards would read as the row running away, not as a page turned —
    /// the momentum decides how fast, `start` (where the drag began) how far.
    /// Faces and media cards are small enough that a fling going several
    /// items is the point, so those rows take the projection (`target`).
    static func snapTarget(
        in row: UICollectionView,
        projected: CGFloat,
        start: CGFloat,
        direction: ForYouRowSnap.Direction?,
        stepped: Bool
    ) -> CGFloat {
        let content = CGRect(origin: .zero, size: row.collectionViewLayout.collectionViewContentSize)
        let items = (row.collectionViewLayout.layoutAttributesForElements(in: content) ?? [])
            .filter { $0.representedElementCategory == .cell }
            .map { $0.frame.minX...$0.frame.maxX }
            .sorted { $0.lowerBound < $1.lowerBound }
        let margin = ForYouRailsView.Metrics.sideMargin
        guard stepped else {
            return ForYouRowSnap.target(
                projected: projected, direction: direction, items: items,
                viewport: row.bounds.width, margin: margin, offsets: offsetRange(of: row)
            )
        }
        return ForYouRowSnap.steppedTarget(
            live: row.contentOffset.x, start: start, direction: direction, items: items,
            viewport: row.bounds.width, margin: margin, offsets: offsetRange(of: row)
        )
    }

    /// Every content offset `row` can rest at.
    static func offsetRange(of row: UIScrollView) -> ClosedRange<CGFloat> {
        let low = -row.adjustedContentInset.left
        let high = row.contentSize.width + row.adjustedContentInset.right - row.bounds.width
        return low...max(low, high)
    }
}

/// Geometry every horizontal row of the lead shares.
@MainActor
enum RowGeometry {
    /// A horizontal row: the lead's look and feel, before its items are known.
    /// Placeholder item size: every item is sized from the width, which the
    /// owner's layout knows and this does not.
    static func makeRow(itemSize: CGSize) -> UICollectionView {
        let layout = UICollectionViewFlowLayout()
        layout.scrollDirection = .horizontal
        layout.itemSize = itemSize
        layout.minimumLineSpacing = ForYouRailsView.Metrics.itemGap
        layout.minimumInteritemSpacing = 0
        let margin = ForYouRailsView.Metrics.sideMargin
        layout.sectionInset = UIEdgeInsets(top: 0, left: margin, bottom: 0, right: margin)
        let row = UICollectionView(frame: .zero, collectionViewLayout: layout)
        row.backgroundColor = .clear
        row.showsHorizontalScrollIndicator = false
        row.alwaysBounceHorizontal = true
        row.alwaysBounceVertical = false
        // A row comes to rest on an item's edge (`RowSnapper`); the quicker
        // deceleration makes that one decided motion rather than a long glide
        // bent to its stop at the end.
        row.decelerationRate = .fast
        // The row sits inside the list's own scroll view, which already
        // accounts for the bars; its horizontal scroll has none to add.
        row.contentInsetAdjustmentBehavior = .never
        // No system band under the header: a row is a scroll view too, and it
        // would draw one — see `prefersClearTopEdge`.
        row.prefersClearTopEdge()
        return row
    }

    static func setItemSize(_ size: CGSize, of row: UICollectionView) {
        guard let layout = row.collectionViewLayout as? UICollectionViewFlowLayout,
              layout.itemSize != size else { return }
        layout.itemSize = size
    }

    /// `view`'s bounds in `space` as they are AT REST: every transform from
    /// `view` up to (not including) `ancestor` left out, `ancestor` and
    /// everything above it converted by UIKit as usual.
    ///
    /// ⚠️ WHERE A FLIGHT LANDS IS WHERE ITS SOURCE RESTS, not where it is
    /// drawn this instant. An item that scales under a press — the disc of a
    /// story, a card's content — reports its SCALED rect through
    /// `convert(_:to:)`, so a close measured while (or because) the press was
    /// still easing out flew to a rect a few points inside the item and off
    /// its centre. Filmed on both rows as "the window doesn't come back to
    /// the right coordinates". The rows' own scroll offsets are NOT
    /// transforms — they are the bounds origins subtracted below — so the row
    /// having scrolled is still honoured; only a transform is ignored.
    ///
    /// Assumes the default anchor point, which is `center`'s meaning.
    static func restingFrame(
        of view: UIView, below ancestor: UIView, in space: UICoordinateSpace
    ) -> CGRect {
        var rect = view.bounds
        var current = view
        while current !== ancestor, let parent = current.superview {
            // From `current`'s bounds space into `parent`'s, as the frame an
            // identity transform would give it: centred on `center`.
            let size = current.bounds.size
            rect = rect.offsetBy(
                dx: current.center.x - size.width / 2 - current.bounds.minX,
                dy: current.center.y - size.height / 2 - current.bounds.minY
            )
            current = parent
        }
        return current.convert(rect, to: space)
    }

    /// Scrolls `row` so the item is wholly in view, flush with the margin on
    /// the side it was cut by — one of the rests a swipe would have left it
    /// on (`ForYouRowSnap`). Before a close measures where it lands, since a
    /// row can be scrolled under an open post.
    static func bringIntoView(_ indexPath: IndexPath, in row: UICollectionView) {
        let margin = ForYouRailsView.Metrics.sideMargin
        row.layoutIfNeeded()
        guard let frame = row.layoutAttributesForItem(at: indexPath)?.frame else { return }
        let visible = row.bounds.insetBy(dx: margin, dy: 0)
        guard !(visible.minX <= frame.minX && frame.maxX <= visible.maxX) else { return }
        row.scrollRectToVisible(frame.insetBy(dx: -margin, dy: 0), animated: false)
        row.layoutIfNeeded()
    }

    /// On screen: in a window, and within its row's visible bounds.
    static func isVisible(_ cell: UICollectionViewCell, in row: UICollectionView) -> Bool {
        cell.window != nil && isInRow(cell, row)
    }

    /// Within its row's visible bounds — what a RECT is asked, window or not.
    ///
    /// ⚠️ NOT `isVisible`. A card-shaped close (`RowCardCloseLanding`) asks
    /// whether the row exists BEFORE the pop has put this screen back in the
    /// window — the swipe stages at its begin — and a window check there
    /// answered "no row", so the close fell to a plain slide
    /// (`geometry=false`, measured). The rect is re-asked in the transition's
    /// own space once the screen is back, as every list's is.
    static func isInRow(_ cell: UICollectionViewCell, _ row: UICollectionView) -> Bool {
        !row.isHidden && row.bounds.intersects(cell.frame)
    }

    /// The lead's "Open" row, first under every long-press preview.
    static func openAction(_ handler: @escaping () -> Void) -> UIAction {
        UIAction(title: "Open", image: UIImage(systemName: "arrow.up.left.and.arrow.down.right")) { _ in
            handler()
        }
    }
}

/// What a lead row's context menu is about — carried in its configuration's
/// identifier, since the menu outlives the index path it was asked for.
enum RowMenuTarget: Equatable {
    case story(ProfileID)
    case card(PostID)

    var identifier: NSString {
        switch self {
        case .story(let id): "story:\(id.rawValue)" as NSString
        case .card(let id): "card:\(id.rawValue)" as NSString
        }
    }

    init?(_ identifier: NSCopying) {
        guard let raw = identifier as? NSString as String? else { return nil }
        if raw.hasPrefix("story:") {
            self = .story(ProfileID(String(raw.dropFirst("story:".count))))
        } else if raw.hasPrefix("card:") {
            self = .card(PostID(String(raw.dropFirst("card:".count))))
        } else {
            return nil
        }
    }
}
