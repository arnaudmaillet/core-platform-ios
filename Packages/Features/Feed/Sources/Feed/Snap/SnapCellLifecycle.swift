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

    /// The screen this cell lives on is LEAVING — popped or dismissed, not
    /// merely covered — so give back every player the viewer is not looking at.
    ///
    /// ⚠️ A THIRD CASE, and it is the one the two above cannot express.
    ///
    /// Resigning without releasing is right for a page swipe and for a screen
    /// that will come back: a paused clip keeps its surface, its frame and its
    /// playhead, and returning to it is free. A screen being popped never comes
    /// back — but it takes the same route, so a gallery's kept neighbours stayed
    /// bound to a decoder nothing could reach again. Measured after opening and
    /// closing one gallery: players still held by a controller on its way out,
    /// and the next tile to be tapped was the one that could not get a decoder.
    ///
    /// The WATCHED surface is deliberately not released here: the dismissal
    /// flight is carrying that very player home to the grid, and taking it back
    /// mid-flight is the thumbnail this whole seam exists to avoid. It goes
    /// through the handoff, as it always did.
    func releaseRetainedNeighbourClips()
}

extension SnapCellLifecycle {
    /// A cell with no clips to keep has nothing to give back.
    func releaseRetainedNeighbourClips() {}
}
