import UIKit

/// What a pager pulled past its FIRST page drives — a surface standing as
/// "page −1" before it (#1739, the owner 2026-10-25: the notifications drawer
/// as a tab before the first tab, reached by the tabs' own gesture).
@MainActor
public protocol LeadingPullTarget: AnyObject {
    /// The pull starts; false refuses it, and the pager rubber-bands as usual.
    func beginLeadingPull() -> Bool
    /// The finger's distance past the first page, in points.
    func updateLeadingPull(_ distance: CGFloat)
    /// Released at `velocity` (points per second, positive rightward).
    func endLeadingPull(velocity: CGFloat)
    /// The finger came back before the first page: nothing happened.
    func cancelLeadingPull()
}

/// Turns a paging scroll view's overscroll past its first page into a pull
/// for a `LeadingPullTarget`, with the scroll view's OWN pan — so reaching
/// "page −1" is exactly the gesture that pages between the others, with the
/// same priority over the page's content.
///
/// While pulling, the scroll view is held on its first page (no rubber band)
/// and the target follows the finger. The distance is measured in WINDOW
/// space: the target typically moves the whole screen, pager included, and a
/// translation read in the pager's own space would chase itself.
@MainActor
public final class LeadingPullTracker {
    public weak var target: (any LeadingPullTarget)?
    private var anchor: CGFloat?
    private var refused = false

    public init() {}

    /// Whether a pull is under way.
    public var isPulling: Bool { anchor != nil }

    /// From the scroll view's `scrollViewDidScroll`.
    public func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard let target, scrollView.isTracking else { return }
        let leading = -scrollView.adjustedContentInset.left
        let translation = scrollView.panGestureRecognizer.translation(in: nil).x
        if anchor == nil {
            guard !refused, scrollView.contentOffset.x < leading - 0.5 else { return }
            guard target.beginLeadingPull() else {
                refused = true
                return
            }
            // The finger is already past the edge by about the overshoot.
            anchor = translation - (leading - scrollView.contentOffset.x)
        }
        let distance = translation - (anchor ?? translation)
        if distance < 0 {
            // Back before the first page: the pull is off, and the pages are the
            // finger's again.
            anchor = nil
            target.cancelLeadingPull()
            return
        }
        if scrollView.contentOffset.x != leading {
            scrollView.contentOffset.x = leading
        }
        target.updateLeadingPull(distance)
    }

    /// From `scrollViewWillEndDragging`: a pull ends where it is, the pager
    /// stays on its first page.
    public func scrollViewWillEndDragging(_ scrollView: UIScrollView, targetContentOffset: UnsafeMutablePointer<CGPoint>) {
        refused = false
        guard anchor != nil else { return }
        anchor = nil
        targetContentOffset.pointee.x = -scrollView.adjustedContentInset.left
        target?.endLeadingPull(velocity: scrollView.panGestureRecognizer.velocity(in: nil).x)
    }

    /// From `scrollViewDidEndDragging`, for a release that did not go through
    /// `willEndDragging` (a cancelled pan).
    public func scrollViewDidEndDragging(_ scrollView: UIScrollView) {
        refused = false
        guard anchor != nil else { return }
        anchor = nil
        target?.cancelLeadingPull()
    }
}
