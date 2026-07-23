import UIKit

/// Magnetic pill snapping, shared by the two map filter bars.
///
/// Both bars scroll their pill row leading-ward under something: the sub bar
/// parks a FIXED glass button over its leading edge and duck-fades cells
/// sliding beneath it; the main bar has no furniture, but its row still runs
/// off the bar's leading margin. A free-scrolling row can therefore come to
/// rest with a pill half-dissolved under the button, or sliced by the bar's
/// edge: too faded to read, too present to ignore. Snapping deletes that
/// state — on release the row lands with a pill's LEADING edge flush against
/// the anchor line.
///
/// That anchor is the collection view's own leading content inset, which is
/// exactly the gap each bar already reserves (the button plus its fade margin
/// in the sub bar, the container margin in the main one). Using it — rather
/// than re-deriving the chrome's geometry — makes the first pill's snap and
/// the row's RESTING offset the same number by construction, so a
/// scrolled-home row can't jitter by a point on release.
@MainActor
enum MapBarSnap {
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
        velocityX: CGFloat
    ) -> CGFloat {
        let inset = collectionView.adjustedContentInset
        let minX = -inset.left
        let maxX = collectionView.contentSize.width + inset.right - collectionView.bounds.width
        // Row shorter than its viewport: nothing scrolls, nothing to align.
        guard maxX > minX else { return proposedX }

        // The anchor in collection-view coordinates: the inner edge of the
        // gap the bar reserves ahead of its row.
        let anchorX = inset.left

        let contentRect = CGRect(origin: .zero, size: collectionView.contentSize)
        let cells = collectionView.collectionViewLayout
            .layoutAttributesForElements(in: contentRect)?
            .filter { $0.representedElementCategory == .cell } ?? []
        guard !cells.isEmpty else { return proposedX }

        let candidates = cells
            .map { min(max($0.frame.minX - anchorX, minX), maxX) }

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
    static func settle(_ collectionView: UICollectionView) {
        let currentX = collectionView.contentOffset.x
        let snappedX = offsetX(snapping: collectionView, proposedX: currentX, velocityX: 0)
        guard abs(snappedX - currentX) > tolerance else { return }
        collectionView.setContentOffset(
            CGPoint(x: snappedX, y: collectionView.contentOffset.y), animated: true
        )
    }
}
