import CoreModels
import FeedInterface
import PostSurfaces
import UIKit
import LaunchArguments

// MARK: - SnapFeedSettleReporting

/// Where the viewer stopped, published to presenters outside this package.
///
/// `activePostID` is already the answer every close inside Feed uses; the
/// conformance simply lets the MAP ask the same question. It has to: the map
/// stages its flight home when the dismissal begins, and the post it is flying
/// away FROM is whatever the viewer paged to, which the map has no other way to
/// learn — it handed over a list of ids and got back a `UIViewController`.
extension SnapFeedViewController: SnapFeedSettleReporting {
    public var settledPostID: PostID? { activePostID }

    /// ⚠️ The SETTLED page's cell, not `activeSnapCell`. That one is gated on
    /// visibility, which is the right gate for playback and the wrong one here:
    /// by the time a dismissal asks, this screen is already reporting itself
    /// invisible, so the visibility-gated cell answers about the wrong post or
    /// about none at all.
    /// The cell for the page the viewer stopped on.
    ///
    /// ⚠️ Not `activeSnapCell`, for the reason `settledCoverImage` states at
    /// length: that one is gated on visibility, which is the right gate for
    /// playback and the wrong one at a dismissal.
    private var settledCell: SnapFeedCell? {
        let index = settledPageIndex
        guard orderedIDs.indices.contains(index) else { return nil }
        return collectionView.cellForItem(at: IndexPath(item: index, section: 0)) as? SnapFeedCell
    }

    public var settledCoverImage: UIImage? {
        let index = settledPageIndex
        guard orderedIDs.indices.contains(index) else { return nil }
        let cell = settledCell
        let still = cell?.currentPageCover
        #if DEBUG
        // `-zoom-blend-log`: WHY there is no picture, which is the only part of
        // this a caller cannot see. An inert blend has three quite different
        // causes — an unrealized cell, a text page, a video with neither a
        // decoded frame nor a poster — and they are the same nil.
        if LaunchArgument.zoomBlendLog.isPassed(), still == nil {
            print("[zoom-blend] no still at page \(index):"
                + " cell=\(cell == nil ? "unrealized" : "realized")"
                + " media=\(modelsByID[orderedIDs[index]]?.mediaURL?.lastPathComponent ?? "none")")
        }
        #endif
        return still
    }
}
