import Testing
@testable import CoreNavigation

/// The released grab's settlement, pinned as a decision table.
///
/// ⚠️ The star pin is the cancel row. The commit row was always right (adopt,
/// then hold); the cancel row just removed the card — and under the
/// `AVPlayerLayer` backing the donation had physically taken the page's render
/// view out of its cell, so a cancelled grab restored a page with a dead media
/// area. `ZoomAnimator`'s cancel branch always gave donated surfaces back;
/// the two drivers stage the same flight and must settle it identically.
struct ZoomGrabSettlementTests {
    /// Cancel with a donated surface: the surface goes home FIRST, and the
    /// card leaves immediately — nothing is landing, so nothing is held.
    @Test func aCancelledGrabGivesItsDonatedSurfaceBack() {
        let plan = ZoomGrabSettlement.plan(cancelled: true, cardHasLiveSurface: true)
        #expect(plan == [
            .restoreDestinationContent, .reclaimSurfaceToDestination,
            .removeCardNow, .concealSource,
        ])
    }

    /// Cancel with a cover-only card: nothing to give back, the card just goes.
    @Test func aCancelledCoverOnlyCardJustLeaves() {
        let plan = ZoomGrabSettlement.plan(cancelled: true, cardHasLiveSurface: false)
        #expect(plan == [.restoreDestinationContent, .removeCardNow, .concealSource])
    }

    /// Commit with live media: the landing tile adopts the surface BEFORE the
    /// hold, so the tile is rendering while the card still covers it.
    @Test func aCommittedGrabHandsItsSurfaceToTheLanding() {
        let plan = ZoomGrabSettlement.plan(cancelled: false, cardHasLiveSurface: true)
        #expect(plan == [.adoptSurfaceToSource, .holdCardOverLanding, .revealSource])
    }

    /// Commit without live media STILL holds the card: a cover-only landing
    /// has the same first-composite gap, and the hold is what keeps it off
    /// screen. (This was the defect where a real finger's dismissal removed
    /// the card on its first line and the tile's cover popped in.)
    @Test func aCommittedCoverOnlyCardIsStillHeldOverTheLanding() {
        let plan = ZoomGrabSettlement.plan(cancelled: false, cardHasLiveSurface: false)
        #expect(plan == [.holdCardOverLanding, .revealSource])
    }

    /// The hand-over always precedes the card's disposal, on every row that
    /// has both — asserted as a property so a reordering cannot slip through
    /// a rewrite of the individual rows.
    @Test(arguments: [true, false])
    func theSurfaceChangesHandsBeforeTheCardIsDisposedOf(cancelled: Bool) throws {
        let plan = ZoomGrabSettlement.plan(cancelled: cancelled, cardHasLiveSurface: true)
        let handOver = try #require(plan.firstIndex {
            $0 == .reclaimSurfaceToDestination || $0 == .adoptSurfaceToSource
        })
        let disposal = try #require(plan.firstIndex {
            $0 == .holdCardOverLanding || $0 == .removeCardNow
        })
        #expect(handOver < disposal)
    }

    /// Exactly one disposal per plan, whatever the inputs: a card both held
    /// and removed would be torn down twice, one neither held nor removed is
    /// stranded over the screen.
    @Test(arguments: [true, false], [true, false])
    func everyPlanDisposesOfTheCardExactlyOnce(cancelled: Bool, live: Bool) {
        let plan = ZoomGrabSettlement.plan(cancelled: cancelled, cardHasLiveSurface: live)
        let disposals = plan.filter { $0 == .holdCardOverLanding || $0 == .removeCardNow }
        #expect(disposals.count == 1)
    }

    /// The two hand-overs are mutually exclusive: a surface reclaimed by the
    /// page AND adopted by the tile would be two owners for one view.
    @Test(arguments: [true, false], [true, false])
    func noPlanHandsTheSurfaceToBothSides(cancelled: Bool, live: Bool) {
        let plan = ZoomGrabSettlement.plan(cancelled: cancelled, cardHasLiveSurface: live)
        let reclaims = plan.contains(.reclaimSurfaceToDestination)
        let adopts = plan.contains(.adoptSurfaceToSource)
        #expect(!(reclaims && adopts))
    }

    /// ⚠️ THE BLACK FRAME, as a property. The page comes back BEFORE anything
    /// is taken from the card, because the card is BELOW the page: revealing
    /// the page covers the card in the same commit, and nothing that happens
    /// to the card afterwards can reach the screen. Reversed — which is what
    /// shipped — the hand-back hides the card's surface and the card's own
    /// ground (the last rung of the picture ladder, black) is composited as
    /// the page for one frame.
    @Test(arguments: [true, false])
    func theCancelledPageComesBackBeforeTheCardIsTouched(live: Bool) throws {
        let plan = ZoomGrabSettlement.plan(cancelled: true, cardHasLiveSurface: live)
        let restore = try #require(plan.firstIndex(of: .restoreDestinationContent))
        let touched = try #require(plan.firstIndex {
            $0 == .reclaimSurfaceToDestination || $0 == .removeCardNow
        })
        #expect(restore < touched)
    }

    /// A committed dismissal never restores the page it is leaving through this
    /// channel: that page is on its way out, and the restore exists only for
    /// the grab that abandoned.
    @Test(arguments: [true, false])
    func aCommittedGrabDoesNotRestoreTheDepartingPage(live: Bool) {
        let plan = ZoomGrabSettlement.plan(cancelled: false, cardHasLiveSurface: live)
        #expect(!plan.contains(.restoreDestinationContent))
    }

    /// Exactly one verdict on the source per plan, and it follows the outcome:
    /// a landing reveals what it landed on, an abandoned grab keeps the twin's
    /// original out of sight because the page is staying over it.
    ///
    /// ⚠️ This is the row that was wrong on screen rather than in code: the
    /// teardown revealed the source unconditionally, so the second grab of a
    /// session flew a card over a marker the viewer could see.
    @Test(arguments: [true, false], [true, false])
    func theSourceVerdictFollowsTheOutcome(cancelled: Bool, live: Bool) {
        let plan = ZoomGrabSettlement.plan(cancelled: cancelled, cardHasLiveSurface: live)
        let verdicts = plan.filter { $0 == .revealSource || $0 == .concealSource }
        #expect(verdicts.count == 1)
        #expect(verdicts.first == (cancelled ? .concealSource : .revealSource))
    }

    /// The source verdict is the LAST word, after the card has been disposed
    /// of: a reveal that ran before the hold would uncover the landing while
    /// the card is still flying onto it.
    @Test(arguments: [true, false], [true, false])
    func theSourceVerdictComesAfterTheCardIsDisposedOf(cancelled: Bool, live: Bool) throws {
        let plan = ZoomGrabSettlement.plan(cancelled: cancelled, cardHasLiveSurface: live)
        let disposal = try #require(plan.firstIndex {
            $0 == .holdCardOverLanding || $0 == .removeCardNow
        })
        let verdict = try #require(plan.firstIndex {
            $0 == .revealSource || $0 == .concealSource
        })
        #expect(disposal < verdict)
    }
}
