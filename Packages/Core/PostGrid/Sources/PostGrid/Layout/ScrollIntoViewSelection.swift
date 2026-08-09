import UIKit

/// Opens the item a viewer tapped, after making sure they can see it.
///
/// Tapping a partially hidden item used to open it from behind the chrome. The
/// grids fix that by revealing it first — but the open must then WAIT, because
/// on these surfaces a tap starts a hero flight, and the flight measures the
/// cell's rect at open time. Opening while the scroll is still moving flies
/// from a rect that is already stale, which is worse than the problem being
/// fixed. Once it settles, the flight measures a fully visible cell, which is
/// strictly better than the clipped one it used to depart from.
///
/// Shared rather than written twice: Discover, Following and the profile
/// gallery all want the same behaviour and only differ in what "open" means.
@MainActor
public final class ScrollIntoViewSelection {
    private var pendingOpen: (() -> Void)?
    private var fallback: DispatchWorkItem?

    /// How long to wait for `scrollViewDidEndScrollingAnimation` before opening
    /// anyway.
    ///
    /// UIKit does not promise that callback: it is skipped when an animation is
    /// pre-empted, and a scroll interrupted by a second touch can end without
    /// it. A tap that opens nothing is a far worse failure than one that opens
    /// a frame early, so the wait has a floor under it.
    private static let settleTimeout: TimeInterval = 0.5

    public init() {}

    /// Reveals `rect` if the chrome is covering it and opens once the scroll
    /// settles; opens immediately when nothing needs to move — which is the
    /// common case and must stay free of delay.
    public func select(
        revealing rect: CGRect?,
        in scrollView: UIScrollView,
        open: @escaping () -> Void
    ) {
        // A tap that lands while an earlier one is still waiting replaces it.
        // Firing the old one too would open two posts from one gesture.
        cancelPending()
        guard let rect, let offset = ScrollIntoView.offset(
            toReveal: rect,
            bounds: scrollView.bounds,
            contentInset: scrollView.adjustedContentInset,
            contentSize: scrollView.contentSize
        ) else {
            open()
            return
        }
        pendingOpen = open
        let work = DispatchWorkItem { [weak self] in self?.fire() }
        fallback = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.settleTimeout, execute: work)
        scrollView.setContentOffset(offset, animated: true)
    }

    /// Call from `scrollViewDidEndScrollingAnimation`.
    public func scrollAnimationDidEnd() {
        fire()
    }

    /// Drops a pending open — for a surface going away, where opening a post
    /// after the fact would be a screen the viewer never asked for.
    public func cancelPending() {
        fallback?.cancel()
        fallback = nil
        pendingOpen = nil
    }

    public var hasPendingOpen: Bool { pendingOpen != nil }

    private func fire() {
        fallback?.cancel()
        fallback = nil
        guard let open = pendingOpen else { return }
        pendingOpen = nil
        open()
    }
}
