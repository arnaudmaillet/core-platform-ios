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
        #expect(plan == [.reclaimSurfaceToDestination, .removeCardNow])
    }

    /// Cancel with a cover-only card: nothing to give back, the card just goes.
    @Test func aCancelledCoverOnlyCardJustLeaves() {
        let plan = ZoomGrabSettlement.plan(cancelled: true, cardHasLiveSurface: false)
        #expect(plan == [.removeCardNow])
    }

    /// Commit with live media: the landing tile adopts the surface BEFORE the
    /// hold, so the tile is rendering while the card still covers it.
    @Test func aCommittedGrabHandsItsSurfaceToTheLanding() {
        let plan = ZoomGrabSettlement.plan(cancelled: false, cardHasLiveSurface: true)
        #expect(plan == [.adoptSurfaceToSource, .holdCardOverLanding])
    }

    /// Commit without live media STILL holds the card: a cover-only landing
    /// has the same first-composite gap, and the hold is what keeps it off
    /// screen. (This was the defect where a real finger's dismissal removed
    /// the card on its first line and the tile's cover popped in.)
    @Test func aCommittedCoverOnlyCardIsStillHeldOverTheLanding() {
        let plan = ZoomGrabSettlement.plan(cancelled: false, cardHasLiveSurface: false)
        #expect(plan == [.holdCardOverLanding])
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
}
