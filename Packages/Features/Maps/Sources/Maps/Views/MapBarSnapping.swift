import UIKit

/// Magnetic pill snapping, shared by the two map filter bars.
///
/// Both bars park a FIXED glass bubble over one edge of a scrolling pill row
/// — the sticky "All" header on the leading edge, the expand button on the
/// trailing one — and duck-fade cells that slide beneath it. A free-scrolling
/// row can therefore come to rest with a pill parked half-dissolved under the
/// glass: too faded to read, too present to ignore. Snapping deletes that
/// state — on release the row lands with a pill boundary flush against the
/// bubble.
///
/// The anchor line is the collection view's own horizontal content inset,
/// which is exactly the gap the bars already reserve for their bubble. Using
/// it (rather than re-deriving the button geometry) makes the first pill's
/// snap and the row's RESTING offset the same number by construction — a
/// scrolled-home row can't jitter by a point on release.
@MainActor
enum MapBarSnap {
    /// Which pill edge lands on the anchor line.
    enum Alignment {
        /// Pill leading edges align just past the leading bubble (main bar).
        case leading
        /// Pill trailing edges align just before the trailing bubble (sub bar).
        case trailing
    }

    /// Points/ms below which a release reads as a nudge rather than a flick;
    /// a nudge may snap in either direction, a flick may not reverse.
    private static let flickVelocity: CGFloat = 0.25

    /// Distance under which a correction isn't worth an animation.
    static let tolerance: CGFloat = 0.5

    /// The resting offset for a release: the pill boundary nearest the
    /// proposed (natural deceleration) offset, clamped to the scrollable
    /// range. Velocity is preserved as *direction* — the native curve still
    /// carries the flick, we only retarget where it stops.
    static func offsetX(
        snapping collectionView: UICollectionView,
        proposedX: CGFloat,
        velocityX: CGFloat,
        alignment: Alignment
    ) -> CGFloat {
        let inset = collectionView.adjustedContentInset
        let minX = -inset.left
        let maxX = collectionView.contentSize.width + inset.right - collectionView.bounds.width
        // Row shorter than its viewport: nothing scrolls, nothing to align.
        guard maxX > minX else { return proposedX }

        // The anchor in collection-view coordinates: the inner edge of the
        // gap the bar reserves for its fixed bubble.
        let anchorX = switch alignment {
        case .leading: inset.left
        case .trailing: collectionView.bounds.width - inset.right
        }

        let contentRect = CGRect(origin: .zero, size: collectionView.contentSize)
        let cells = collectionView.collectionViewLayout
            .layoutAttributesForElements(in: contentRect)?
            .filter { $0.representedElementCategory == .cell } ?? []
        guard !cells.isEmpty else { return proposedX }

        let candidates = cells
            .map { alignment == .leading ? $0.frame.minX : $0.frame.maxX }
            .map { min(max($0 - anchorX, minX), maxX) }

        // A flick keeps its direction — snapping back past the release point
        // would fight the gesture. If it flicked clean off the end, the
        // clamped candidates still catch it (the filter falls back to all).
        let currentX = collectionView.contentOffset.x
        let directional = if velocityX > flickVelocity {
            candidates.filter { $0 > currentX + tolerance }
        } else if velocityX < -flickVelocity {
            candidates.filter { $0 < currentX - tolerance }
        } else {
            candidates
        }
        let pool = directional.isEmpty ? candidates : directional
        return pool.min { abs($0 - proposedX) < abs($1 - proposedX) } ?? proposedX
    }

    /// Post-deceleration correction. Off-screen pills carry ESTIMATED widths
    /// until they are measured, so a long flick can be retargeted against a
    /// layout that shifts under it; this re-aligns once the real geometry
    /// exists. A no-op (sub-point) in the common case, so it can be wired to
    /// every scroll end without reading as a second animation.
    static func settle(_ collectionView: UICollectionView, alignment: Alignment) {
        let currentX = collectionView.contentOffset.x
        let snappedX = offsetX(
            snapping: collectionView, proposedX: currentX, velocityX: 0, alignment: alignment
        )
        guard abs(snappedX - currentX) > tolerance else { return }
        collectionView.setContentOffset(
            CGPoint(x: snappedX, y: collectionView.contentOffset.y), animated: true
        )
    }
}
