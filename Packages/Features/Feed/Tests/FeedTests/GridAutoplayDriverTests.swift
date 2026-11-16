import CoreModels
import Foundation
import PostGrid
import Testing
import UIKit
@testable import Feed
@testable import PostSurfaces

/// The For You grid's autoplay decisions, without a collection view, a window
/// or the wall clock (#858).
///
/// The page measures; `GridAutoplayDriver` decides. These pin the
/// decisions: which measured tiles the viewport admits and how far each is
/// from its centre, which of them are held but paused, how many players the
/// page may hold beside a lead, and when a scroll tick may start anything.
@MainActor
struct GridAutoplayDriverTests {
    private static let clip = URL(string: "https://media.test/clip.m3u8")!
    private static let otherClip = URL(string: "https://media.test/other.m3u8")!
    /// A 400pt-tall band from y 100 to 500, centred on y 300.
    private static let viewport = CGRect(x: 0, y: 100, width: 390, height: 400)

    /// A cell is only carried through to the coordinator; nothing is drawn.
    private func tile(
        _ id: String, minY: CGFloat, height: CGFloat = 100, advancing: Bool = true
    ) -> GridAutoplayDriver.Tile {
        .init(
            id: PostID(id), url: Self.clip,
            cell: PostGridTileCell(frame: CGRect(x: 0, y: 0, width: 130, height: height)),
            mediaFrame: CGRect(x: 0, y: minY, width: 130, height: height),
            isPaused: !advancing
        )
    }

    // MARK: - Budget

    @Test func theBudgetIsTheShapesNumberWhenTheLeadHoldsNothing() {
        #expect(GridAutoplayDriver.playerBudget(for: .grid, poolCapacity: 6, reserve: 0) == 6)
        #expect(GridAutoplayDriver.playerBudget(for: .list, poolCapacity: 6, reserve: 0) == 5)
        #expect(GridAutoplayDriver.playerBudget(for: .discover, poolCapacity: 6, reserve: 0) == 5)
    }

    /// For You's Following row plays up to three cards from the same pool:
    /// the list gives way rather than starving one of the six decoders.
    @Test func aLeadsPlayersComeOutOfTheListsShare() {
        #expect(GridAutoplayDriver.playerBudget(for: .list, poolCapacity: 6, reserve: 3) == 3)
        #expect(GridAutoplayDriver.playerBudget(for: .grid, poolCapacity: 6, reserve: 1) == 5)
    }

    @Test func aLeadHoldingMoreThanThePoolLeavesTheListNothingRatherThanANegativeBudget() {
        #expect(GridAutoplayDriver.playerBudget(for: .list, poolCapacity: 6, reserve: 9) == 0)
    }

    @Test func aLargerPoolNeverLiftsTheShapesCeiling() {
        #expect(GridAutoplayDriver.playerBudget(for: .grid, poolCapacity: 12, reserve: 0) == 6)
    }

    @Test func thePageForwardsItsConcurrencyToTheDriver() {
        for style in [PostGridPageView.Style.grid, .list, .discover] {
            #expect(PostGridPageView.concurrentPlayers(for: style)
                == GridAutoplayDriver.concurrentPlayers(for: style))
        }
    }

    // MARK: - Candidates

    @Test func aTileHalfInsideTheViewportIsAdmitted() {
        // 50 of 100pt inside, exactly the minimum fraction.
        let candidates = GridAutoplayDriver.candidates(
            from: [tile("edge", minY: 50)], in: Self.viewport
        )
        #expect(candidates.map(\.id) == [PostID("edge")])
    }

    @Test func aTileCreepingInAtTheEdgeIsNotAdmitted() {
        // 40 of 100pt inside.
        let candidates = GridAutoplayDriver.candidates(
            from: [tile("creeping", minY: 460)], in: Self.viewport
        )
        #expect(candidates.isEmpty)
    }

    @Test func distanceIsMeasuredFromTheViewportsCentreToTheMediasCentre() {
        let candidates = GridAutoplayDriver.candidates(
            from: [tile("centred", minY: 250), tile("above", minY: 120), tile("below", minY: 380)],
            in: Self.viewport
        )
        #expect(candidates.map(\.distanceFromCentre) == [0, 130, 130])
    }

    @Test func admittedTilesKeepTheOrderTheyCameIn() {
        let candidates = GridAutoplayDriver.candidates(
            from: [tile("b", minY: 380), tile("off", minY: 900), tile("a", minY: 250)],
            in: Self.viewport
        )
        #expect(candidates.map(\.id) == [PostID("b"), PostID("a")])
    }

    @Test func aTileThatIsNotAdvancingIsHandedOverPaused() {
        let candidates = GridAutoplayDriver.candidates(
            from: [tile("peeking", minY: 250, advancing: false), tile("watched", minY: 120)],
            in: Self.viewport
        )
        #expect(candidates.map(\.isPaused) == [true, false])
    }

    @Test func theCellAndTheStreamAreCarriedThrough() {
        let measured = tile("carried", minY: 250)
        let candidate = GridAutoplayDriver.candidates(from: [measured], in: Self.viewport).first
        #expect(candidate?.url == Self.clip)
        #expect(candidate?.cell === measured.cell)
    }

    // MARK: - Advancing

    /// A single attachment is always on its own page: `currentPageVideoURL`
    /// is nil for it, and that must not read as "on another page".
    @Test func aSingleVideoRowIsAlwaysAdvancing() {
        #expect(GridAutoplayDriver.isAdvancing(
            showsCarousel: false, currentPageVideoURL: nil, held: Self.clip
        ))
    }

    @Test func aCarouselOnItsClipsPageIsAdvancing() {
        #expect(GridAutoplayDriver.isAdvancing(
            showsCarousel: true, currentPageVideoURL: Self.clip, held: Self.clip
        ))
    }

    @Test func aCarouselOnAPhotographBesideItsClipIsHeldButNotAdvancing() {
        #expect(!GridAutoplayDriver.isAdvancing(
            showsCarousel: true, currentPageVideoURL: nil, held: Self.clip
        ))
        #expect(!GridAutoplayDriver.isAdvancing(
            showsCarousel: true, currentPageVideoURL: Self.otherClip, held: Self.clip
        ))
    }

    // MARK: - During-scroll reconcile

    @Test func aTickInsideTheThrottleWindowAsksForNoReconcile() {
        var driver = GridAutoplayDriver()
        #expect(driver.scrollTick(offset: 0, at: 10) == true)
        #expect(driver.scrollTick(offset: 5, at: 10 + GridAutoplayDriver.scrollReconcileInterval / 2) == nil)
    }

    /// The window is closed at its end: a tick exactly one interval after the
    /// last sample reconciles, one a hair earlier does not. A fresh driver's
    /// last sample is at time zero.
    @Test func aTickExactlyOneIntervalLaterReconcilesAndOneJustShortDoesNot() {
        let interval = GridAutoplayDriver.scrollReconcileInterval
        var early = GridAutoplayDriver()
        #expect(early.scrollTick(offset: 0, at: interval.nextDown) == nil)
        var onTime = GridAutoplayDriver()
        #expect(onTime.scrollTick(offset: 0, at: interval) != nil)
    }

    @Test func aTickPastTheIntervalReconcilesAgain() {
        var driver = GridAutoplayDriver()
        _ = driver.scrollTick(offset: 0, at: 10)
        #expect(driver.scrollTick(offset: 10, at: 10 + GridAutoplayDriver.scrollReconcileInterval * 1.5) == true)
    }

    @Test func aHandDragStartsPlayers() {
        var driver = GridAutoplayDriver()
        _ = driver.scrollTick(offset: 0, at: 10)
        // 1500 pt/s over a tenth of a second.
        #expect(driver.scrollTick(offset: 150, at: 10.1) == true)
    }

    @Test func aHardFlingStartsNothing() {
        var driver = GridAutoplayDriver()
        _ = driver.scrollTick(offset: 0, at: 10)
        // 4000 pt/s over a tenth of a second.
        #expect(driver.scrollTick(offset: 400, at: 10.1) == false)
    }

    /// Times and offsets exact in binary, so the velocity lands ON the
    /// threshold rather than a rounding error either side of it.
    @Test func theFlingGateSitsAtExactlyTheMaximumStartVelocity() {
        var driver = GridAutoplayDriver()
        _ = driver.scrollTick(offset: 0, at: 10)
        // 275pt in 0.125 s = 2200 pt/s: still starts.
        #expect(driver.scrollTick(offset: 275, at: 10.125) == true)
        // 276pt in 0.125 s = 2208 pt/s: does not.
        #expect(driver.scrollTick(offset: 551, at: 10.25) == false)
    }

    /// The velocity is measured since the last tick that reconciled, not the
    /// last tick at all: a throttled tick does not move the sample.
    @Test func aThrottledTickDoesNotMoveTheVelocitySample() {
        var driver = GridAutoplayDriver()
        _ = driver.scrollTick(offset: 0, at: 10)
        #expect(driver.scrollTick(offset: 1000, at: 10.01) == nil)
        // 150pt since the sample at 10.0, over a tenth of a second.
        #expect(driver.scrollTick(offset: 150, at: 10.1) == true)
    }

    @Test func scrollingBackUpIsMeasuredAsFastAsScrollingDown() {
        var driver = GridAutoplayDriver()
        _ = driver.scrollTick(offset: 1000, at: 10)
        #expect(driver.scrollTick(offset: 600, at: 10.1) == false)
    }

    // MARK: - Warm window

    @Test func theWarmTakesAtMostFourVisiblePostsInOnScreenOrder() {
        #expect(GridAutoplayDriver.warmIndices(
            visibleFlatIndices: [3, 4, 5, 6, 7, 8, 9], postCount: 20
        ) == [3, 4, 5, 6])
    }

    @Test func theWarmSkipsIndicesThatNoLongerNameAPost() {
        #expect(GridAutoplayDriver.warmIndices(
            visibleFlatIndices: [8, 9, 10, 11], postCount: 10
        ) == [8, 9])
    }
}
