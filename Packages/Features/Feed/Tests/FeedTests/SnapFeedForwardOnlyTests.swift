import Testing
import UIKit
@testable import Feed

/// The forward-only feed (cluster-gallery milestone): backward vertical
/// paging is gone — the whole downward direction belongs to the dismissal
/// hero. Two pure rules carry it: the pager's per-touch decline of downward
/// movements, and the engaged page-drive's refusal to step to the previous
/// post.
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

    // MARK: - The engaged page-drive's step rule

    private let page: CGFloat = 800

    @Test func aDecisiveUpwardDriveAdvances() {
        #expect(SnapFeedViewController.pageDriveStep(translation: -200, velocity: 0, page: page) == 1)
        #expect(SnapFeedViewController.pageDriveStep(translation: -40, velocity: -600, page: page) == 1)
    }

    /// The forward-only change: this used to answer -1 (previous post).
    @Test func aDecisiveDownwardDriveSettlesHomeInsteadOfPagingBack() {
        #expect(SnapFeedViewController.pageDriveStep(translation: 200, velocity: 0, page: page) == 0)
        #expect(SnapFeedViewController.pageDriveStep(translation: 40, velocity: 600, page: page) == 0)
    }

    @Test func anIndecisiveDriveSettlesHome() {
        #expect(SnapFeedViewController.pageDriveStep(translation: -40, velocity: -100, page: page) == 0)
        #expect(SnapFeedViewController.pageDriveStep(translation: 40, velocity: 100, page: page) == 0)
    }

    /// A decisive drag whose velocity has already reversed projects HOME, not
    /// forward — the finger changed its mind and the projection (drag + a
    /// slice of velocity) is what decides.
    @Test func aReversedProjectionSettlesHome() {
        #expect(SnapFeedViewController.pageDriveStep(translation: -150, velocity: 800, page: page) == 0)
    }
}
