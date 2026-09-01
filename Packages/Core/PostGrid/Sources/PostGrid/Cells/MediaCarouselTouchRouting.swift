import UIKit

/// WHETHER A HORIZONTAL DRAG THAT LANDS ON A CAROUSEL BELONGS TO IT.
///
/// The rule is what the drag could otherwise do, and it is the same one
/// `ProfileDismissalPolicy` states for tabs and `HorizontalPagerScrollView` for
/// the pager: on a page with a neighbour in that direction the carousel is the
/// tenant and wins its own territory; with nothing there, holding the gesture
/// would spend it on a rubber-band, so it passes straight through to the surface
/// around it — the screen's dismissal, or whatever else was listening.
///
/// ⚠️ SHARED because the walk was written inside one screen's dismissal gate and
/// the next screen with a gallery on it was about to copy it. That is the
/// mistake `HorizontalPagerScrollView` records having already made once, with two
/// pagers: the fix went into one of them and changed nothing on the surface it
/// was reported against. One walk, so a second surface cannot drift from the
/// first.
///
/// ⚠️ IN PostGrid, not in DesignSystem where the pager's own half of this rule
/// lives, because it has to NAME `MediaCarouselView` — and DesignSystem sits
/// below PostGrid in the package graph (PostGrid depends on DesignSystem, never
/// the reverse), so the edge does not exist and adding it would be a cycle. The
/// alternative, a protocol in DesignSystem with exactly one conformer, buys the
/// shared location by making the rule harder to read. Both callers already
/// import PostGrid.
@MainActor
public enum MediaCarouselTouchRouting {
    /// The carousel under `point`, or nil when the touch lands on none.
    ///
    /// - Parameters:
    ///   - point: in `host`'s own coordinates. A caller holding a location in
    ///     some other view converts first — the screen's own view and its
    ///     collection view are not the same space once the latter has scrolled.
    ///   - host: the view the touch is hit-tested against, not the window.
    public static func carousel(at point: CGPoint, in host: UIView) -> MediaCarouselView? {
        guard let hit = host.hitTest(point, with: nil) else { return nil }
        for current in sequence(first: hit, next: { $0.superview }) {
            if let carousel = current as? MediaCarouselView { return carousel }
            // Stops at the host: anything above it merely CONTAINS the touch,
            // it is not under it.
            if current === host { break }
        }
        return nil
    }

    /// Whether a horizontal drag beginning at `point` passes THROUGH whatever
    /// carousel is under it.
    ///
    /// `pageDelta` is in pages, which run the opposite way to the finger: a
    /// rightward drag uncovers the page before the current one and asks for
    /// `-1`, a leftward drag asks for `+1`. Taking the delta rather than
    /// assuming one is what lets a surface whose dismissal is armed the other
    /// way ask the same question — see `MediaCarouselView.yieldsRightwardDrag`
    /// for why no surface asks it leftward today.
    ///
    /// A touch that lands on no carousel passes through: that is the answer for
    /// the whole of a screen with no collection on it, and for a text post.
    public static func dragPassesThroughCarousel(
        at point: CGPoint, in host: UIView, towardsPageDelta pageDelta: Int
    ) -> Bool {
        guard let carousel = carousel(at: point, in: host) else { return true }
        return !carousel.hasTravel(towardsPageDelta: pageDelta)
    }
}
