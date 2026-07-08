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
    func didResignActive()
}
