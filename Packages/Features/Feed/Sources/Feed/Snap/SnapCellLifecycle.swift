import UIKit

/// The activation contract every full-screen snap cell honours.
///
/// Exactly one cell is *active* — the page snapped to the viewport — and only
/// while the feed surface itself is visible (frontmost tab, app foregrounded).
/// In Phase 1 an image cell uses these two calls to start/stop a subtle
/// Ken Burns motion, which makes activation observable and testable. In
/// Phase 2 the video cell attaches/detaches a pooled `AVPlayer` on the exact
/// same calls — so the whole activation machinery ships and is exercised now.
@MainActor
protocol SnapCellLifecycle: AnyObject {
    /// This cell became the single active page on a visible surface.
    func willBecomeActive()
    /// This cell is no longer the active page, or the surface went away.
    ///
    /// - Parameter releasingPlayback: whether the page should give its player
    ///   back to the pool.
    ///
    ///   ⚠️ THE TWO REASONS ARE NOT THE SAME, and treating them alike is what
    ///   put a thumbnail on screen at every page change. Paging to the next post
    ///   leaves this one alive and a swipe away; releasing its player there
    ///   means the return pays for a fresh decode, and the surface falls back to
    ///   its poster in the meantime — the cut the viewer sees. Scrolling the
    ///   cell fully off screen is the other case, and there the loan genuinely
    ///   has to go back: the grid behind is waiting for it.
    func didResignActive(releasingPlayback: Bool)
}
