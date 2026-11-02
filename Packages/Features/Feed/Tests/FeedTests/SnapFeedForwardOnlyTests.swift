import Testing
import UIKit
@testable import Feed

/// The pager's downward axis test.
///
/// The feed was forward-only (cluster-gallery milestone, #114). Since #2057
/// a downward drag on a later post pages back through the pager — who owns
/// it is `SnapVerticalDragRouter`'s (`SnapVerticalDragRouterTests`). The
/// drive (text pages, engaged comments) steps both ways since #2058
/// (`SnapPageDriveTests`).
struct SnapFeedForwardOnlyTests {
    // MARK: - The pager's per-touch decline

    @Test func aDownwardVerticalTouchIsDeclined() {
        #expect(SnapFeedCollectionView.declinesDownwardPagingTouch(velocity: CGPoint(x: 0, y: 300)))
        #expect(SnapFeedCollectionView.declinesDownwardPagingTouch(velocity: CGPoint(x: 100, y: 400)))
    }

    @Test func anUpwardTouchStaysWithThePager() {
        #expect(!SnapFeedCollectionView.declinesDownwardPagingTouch(velocity: CGPoint(x: 0, y: -300)))
        #expect(!SnapFeedCollectionView.declinesDownwardPagingTouch(velocity: CGPoint(x: 50, y: -400)))
    }

    /// A rightward drag with some downward drift is the DISMISSAL's horizontal
    /// grab (or nothing) — but it is not the pager's to refuse: the pager has
    /// no horizontal gestures, so refusing here would be a no-op that still
    /// mis-states the rule. Only predominantly-vertical downward movements
    /// are declined.
    @Test func aHorizontallyDominantTouchIsNotThePagersToDecline() {
        #expect(!SnapFeedCollectionView.declinesDownwardPagingTouch(velocity: CGPoint(x: 500, y: 200)))
    }

    @Test func aRestingTouchIsNotDeclined() {
        #expect(!SnapFeedCollectionView.declinesDownwardPagingTouch(velocity: .zero))
    }

    // The engaged page-drive's step rule moved to `SnapPageDriveTests` (#2058).
}
