import UIKit

// MARK: - Geometric touch divorce

/// The feed's collection view, amended with one rule: touches born inside a
/// shortcut rail belong to the rail, so NONE of the pager's own recognizers
/// (its pan, iOS 26's paging swipe) may begin there. This is the inversion
/// that finally made the rail responsive — a scroll view nested in a PAGING
/// scroll view loses UIKit's usual inner-first arbitration (the paging
/// ancestor's recognizers outrank descendants), and every attempt to fight
/// upward from the rail (delegate shadowing, require(toFail:) edges) broke
/// system machinery. Here the pager simply DECLINES, per touch, via the
/// public `gestureRecognizerShouldBegin` seam — the same pattern as the
/// ticker's axis test, with zero edges added to the gesture graph. Left of
/// the rail's column nothing hit-tests into the rail, so the feed is stock.
final class SnapFeedCollectionView: UICollectionView {
    /// Whether an upward touch at a location (in this view's space) belongs to
    /// the swipe-up close past a finished source (#628). Asked only for a
    /// predominantly-upward pan; nil (a feed with no such end) never yields.
    var yieldsUpwardTouch: ((CGPoint) -> Bool)?
    /// Whether a downward drag beginning now is the pager's — it pages BACK
    /// to the previous post (#2057) — rather than the screen's dismissal:
    /// `SnapVerticalDragRouter`'s answer, which the dismissal's own gate asks
    /// too. Nil: the dismissal's, as on a feed with nothing to page back to.
    var ownsDownwardTouch: (() -> Bool)?

    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        let location = gestureRecognizer.location(in: self)
        if let hit = hitTest(location, with: nil), Self.claimsTouches(hit) {
            return false
        }
        // A DOWNWARD touch is the pager's only where the router says so
        // (#2057): on a later post it pages back; on the first it is the
        // dismissal's — declined here, per touch, via the same public seam as
        // the rail divorce, no gesture-graph edges. The dismissal pans ask the
        // same router (`zoomVerticalDismissalPermitted`), so exactly one of
        // the two ever claims a drag. Declined, there is no top rubber-band
        // and no pull-to-refresh either (#114).
        if let pan = gestureRecognizer as? UIPanGestureRecognizer,
           Self.declinesDownwardPagingTouch(velocity: pan.velocity(in: self)),
           ownsDownwardTouch?() != true {
            return false
        }
        // And at the true end, the UPWARD touch too — handed to the close the
        // same way (#628). Anywhere else upward is the next post, as ever.
        if let pan = gestureRecognizer as? UIPanGestureRecognizer,
           Self.isUpwardTouch(velocity: pan.velocity(in: self)),
           yieldsUpwardTouch?(pan.location(in: self)) == true {
            return false
        }
        return super.gestureRecognizerShouldBegin(gestureRecognizer)
    }

    /// A predominantly-upward movement — the upward grab's begin rule
    /// (`ZoomDismissAxis.match`), mirrored. Pure, for tests.
    static func isUpwardTouch(velocity: CGPoint) -> Bool {
        velocity.y < 0 && abs(velocity.y) > abs(velocity.x)
    }

    /// The downward axis test, mirrored from the dismissal pan's begin gate
    /// (`ZoomDismissAxis.match(.vertical)`): a downward, predominantly-
    /// vertical movement — the pager's only where the router gives it.
    /// Pure so the routing rule is unit-testable.
    static func declinesDownwardPagingTouch(velocity: CGPoint) -> Bool {
        velocity.y > 0 && abs(velocity.y) > abs(velocity.x)
    }

    /// The swipe exit's missing half: `UIScrollView` refuses BY DEFAULT to
    /// cancel touches that began on a `UIControl` — and the composer band
    /// is made of controls (the "+", the ✕/send), so a drag born there
    /// could never be taken over by the pager even though the arbitration
    /// allows it. Bar territory explicitly opts INTO cancellation: a
    /// vertical drag on the input band becomes a page change; taps still
    /// land as taps (cancellation only happens once the pan recognizes).
    override func touchesShouldCancel(in view: UIView) -> Bool {
        if sequence(first: view, next: { $0.superview }).contains(where: { $0 is CommentsInputBar }) {
            return true
        }
        return super.touchesShouldCancel(in: view)
    }

    /// Whether the hit view lives inside territory that owns its own
    /// vertical/horizontal gestures, so NONE of the pager's recognizers may
    /// begin there: the shortcut rail (including its fixed compose "+", a
    /// chrome sibling above the rail), and the engaged comments container.
    /// While engaged this is DEFENSE IN DEPTH under the primary rule (the
    /// pager is disabled outright — the total dead-end doctrine); the
    /// composer-band exception is retained but inert, since the bar's own
    /// pan drives the swipe exit programmatically. Pure walk-up so the
    /// routing rule is unit-testable.
    static func claimsTouches(_ view: UIView) -> Bool {
        for current in sequence(first: view, next: { $0.superview }) {
            if current is CommentsInputBar { return false }
            if current is SnapShortcutRailView || current is SnapWheelGlassView || current is SnapRailBoostButton
                || current is SnapCommentsContainerView {
                return true
            }
        }
        return false
    }
}
