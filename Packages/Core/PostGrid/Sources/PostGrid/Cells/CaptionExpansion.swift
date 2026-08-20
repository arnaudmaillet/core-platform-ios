import CoreModels
import UIKit

/// Which posts have had their caption opened out, for a surface that shows
/// `PostGridListRowCell`s.
///
/// The state cannot live in the cell. A cell is recycled, so a row scrolled off
/// and back would come home truncated — or, worse, wearing the expansion of
/// whatever post used that cell in between. It belongs to the surface, keyed by
/// post, and `configure(with:imagePipeline:captionExpanded:)` hands it back on
/// every dequeue.
///
/// A type rather than a bare `Set` in each host: there are two hosts (the For
/// You timeline and the profile gallery) and the interesting part is not the
/// set but what has to happen after it changes — a self-sizing row that just
/// grew has to be re-measured, and `performBatchUpdates(nil)` is the one call
/// that does that without rebuilding the cell and losing the animation.
@MainActor
public final class CaptionExpansion {
    private var expanded: Set<PostID> = []

    public init() {}

    public func isExpanded(_ id: PostID) -> Bool { expanded.contains(id) }

    /// Records the expansion and re-measures `collectionView`.
    ///
    /// `performBatchUpdates(nil)` rather than `reloadItems`: a reload dequeues
    /// a fresh cell, which drops the caption the viewer is reading and snaps to
    /// the new height. An empty batch update asks the layout to re-ask its
    /// self-sizing cells for their size and animates from one to the other,
    /// which is the row growing rather than being replaced.
    public func expand(_ id: PostID, in collectionView: UICollectionView) {
        guard expanded.insert(id).inserted else { return }
        collectionView.performBatchUpdates(nil)
    }

    /// Drops every expansion — a new corpus is not the old one, and an id that
    /// happens to repeat should not arrive already open.
    public func reset() {
        expanded.removeAll()
    }
}
