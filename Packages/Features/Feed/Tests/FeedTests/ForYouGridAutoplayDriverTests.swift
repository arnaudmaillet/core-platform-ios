import CoreModels
import Foundation
import PostGrid
import Testing
import UIKit
@testable import Feed

/// The For You grid's autoplay decisions, without a collection view, a window
/// or the wall clock (#858).
///
/// The page measures; `ForYouGridAutoplayDriver` decides. These pin the
/// decisions: which measured tiles the viewport admits and how far each is
/// from its centre, which of them are held but paused, how many players the
/// page may hold beside a lead, and when a scroll tick may start anything.
@MainActor
struct ForYouGridAutoplayDriverTests {
    private static let clip = URL(string: "https://media.test/clip.m3u8")!
    private static let otherClip = URL(string: "https://media.test/other.m3u8")!
    /// A 400pt-tall band from y 100 to 500, centred on y 300.
    private static let viewport = CGRect(x: 0, y: 100, width: 390, height: 400)

    /// A cell is only carried through to the coordinator; nothing is drawn.
    private func tile(
        _ id: String, minY: CGFloat, height: CGFloat = 100, advancing: Bool = true
    ) -> ForYouGridAutoplayDriver.Tile {
        .init(
            id: PostID(id), url: Self.clip,
            cell: PostGridTileCell(frame: CGRect(x: 0, y: 0, width: 130, height: height)),
            mediaFrame: CGRect(x: 0, y: minY, width: 130, height: height),
            isAdvancing: advancing
        )
    }

    // MARK: - Budget

    @Test func theBudgetIsTheShapesNumberWhenTheLeadHoldsNothing() {
        #expect(ForYouGridAutoplayDriver.playerBudget(for: .grid, poolCapacity: 6, reserve: 0) == 6)
        #expect(ForYouGridAutoplayDriver.playerBudget(for: .list, poolCapacity: 6, reserve: 0) == 5)
        #expect(ForYouGridAutoplayDriver.playerBudget(for: .discover, poolCapacity: 6, reserve: 0) == 5)
    }

    /// For You's Following row plays up to three cards from the same pool:
    /// the list gives way rather than starving one of the six decoders.
    @Test func aLeadsPlayersComeOutOfTheListsShare() {
        #expect(ForYouGridAutoplayDriver.playerBudget(for: .list, poolCapacity: 6, reserve: 3) == 3)
        #expect(ForYouGridAutoplayDriver.playerBudget(for: .grid, poolCapacity: 6, reserve: 1) == 5)
    }

    @Test func aLeadHoldingMoreThanThePoolLeavesTheListNothingRatherThanANegativeBudget() {
        #expect(ForYouGridAutoplayDriver.playerBudget(for: .list, poolCapacity: 6, reserve: 9) == 0)
    }

    @Test func aLargerPoolNeverLiftsTheShapesCeiling() {
        #expect(ForYouGridAutoplayDriver.playerBudget(for: .grid, poolCapacity: 12, reserve: 0) == 6)
    }

    @Test func thePageForwardsItsConcurrencyToTheDriver() {
        for style in [ForYouGridPage.Style.grid, .list, .discover] {
            #expect(ForYouGridPage.concurrentPlayers(for: style)
                == ForYouGridAutoplayDriver.concurrentPlayers(for: style))
        }
    }

    // MARK: - Candidates

    @Test func aTileHalfInsideTheViewportIsAdmitted() {
        // 50 of 100pt inside, exactly the minimum fraction.
        let candidates = ForYouGridAutoplayDriver.candidates(
            from: [tile("edge", minY: 50)], in: Self.viewport
        )
        #expect(candidates.map(\.id) == [PostID("edge")])
    }

    @Test func aTileCreepingInAtTheEdgeIsNotAdmitted() {
        // 40 of 100pt inside.
        let candidates = ForYouGridAutoplayDriver.candidates(
            from: [tile("creeping", minY: 460)], in: Self.viewport
        )
        #expect(candidates.isEmpty)
    }

    @Test func distanceIsMeasuredFromTheViewportsCentreToTheMediasCentre() {
        let candidates = ForYouGridAutoplayDriver.candidates(
            from: [tile("centred", minY: 250), tile("above", minY: 120), tile("below", minY: 380)],
            in: Self.viewport
        )
        #expect(candidates.map(\.distanceFromCentre) == [0, 130, 130])
    }

    @Test func admittedTilesKeepTheOrderTheyCameIn() {
        let candidates = ForYouGridAutoplayDriver.candidates(
            from: [tile("b", minY: 380), tile("off", minY: 900), tile("a", minY: 250)],
            in: Self.viewport
        )
        #expect(candidates.map(\.id) == [PostID("b"), PostID("a")])
    }

    @Test func aTileThatIsNotAdvancingIsHandedOverPaused() {
        let candidates = ForYouGridAutoplayDriver.candidates(
            from: [tile("peeking", minY: 250, advancing: false), tile("watched", minY: 120)],
            in: Self.viewport
        )
        #expect(candidates.map(\.isPaused) == [true, false])
    }

    @Test func theCellAndTheStreamAreCarriedThrough() {
        let measured = tile("carried", minY: 250)
        let candidate = ForYouGridAutoplayDriver.candidates(from: [measured], in: Self.viewport).first
        #expect(candidate?.url == Self.clip)
        #expect(candidate?.cell === measured.cell)
    }

    // MARK: - Advancing

    /// A single attachment is always on its own page: `currentPageVideoURL`
    /// is nil for it, and that must not read as "on another page".
    @Test func aSingleVideoRowIsAlwaysAdvancing() {
        #expect(ForYouGridAutoplayDriver.isAdvancing(
            showsCarousel: false, currentPageVideoURL: nil, held: Self.clip
        ))
    }

    @Test func aCarouselOnItsClipsPageIsAdvancing() {
        #expect(ForYouGridAutoplayDriver.isAdvancing(
            showsCarousel: true, currentPageVideoURL: Self.clip, held: Self.clip
        ))
    }

    @Test func aCarouselOnAPhotographBesideItsClipIsHeldButNotAdvancing() {
        #expect(!ForYouGridAutoplayDriver.isAdvancing(
            showsCarousel: true, currentPageVideoURL: nil, held: Self.clip
        ))
        #expect(!ForYouGridAutoplayDriver.isAdvancing(
            showsCarousel: true, currentPageVideoURL: Self.otherClip, held: Self.clip
        ))
    }

    // MARK: - During-scroll reconcile

    @Test func aTickInsideTheThrottleWindowAsksForNoReconcile() {
        var driver = ForYouGridAutoplayDriver()
        #expect(driver.scrollTick(offset: 0, at: 10) == true)
        #expect(driver.scrollTick(offset: 5, at: 10 + ForYouGridAutoplayDriver.scrollReconcileInterval / 2) == nil)
    }

    @Test func aTickPastTheIntervalReconcilesAgain() {
        var driver = ForYouGridAutoplayDriver()
        _ = driver.scrollTick(offset: 0, at: 10)
        #expect(driver.scrollTick(offset: 10, at: 10 + ForYouGridAutoplayDriver.scrollReconcileInterval * 1.5) == true)
    }

    @Test func aHandDragStartsPlayers() {
        var driver = ForYouGridAutoplayDriver()
        _ = driver.scrollTick(offset: 0, at: 10)
        // 1500 pt/s over a tenth of a second.
        #expect(driver.scrollTick(offset: 150, at: 10.1) == true)
    }

    @Test func aHardFlingStartsNothing() {
        var driver = ForYouGridAutoplayDriver()
        _ = driver.scrollTick(offset: 0, at: 10)
        // 4000 pt/s over a tenth of a second.
        #expect(driver.scrollTick(offset: 400, at: 10.1) == false)
    }

    /// Times and offsets exact in binary, so the velocity lands ON the
    /// threshold rather than a rounding error either side of it.
    @Test func theFlingGateSitsAtExactlyTheMaximumStartVelocity() {
        var driver = ForYouGridAutoplayDriver()
        _ = driver.scrollTick(offset: 0, at: 10)
        // 275pt in 0.125 s = 2200 pt/s: still starts.
        #expect(driver.scrollTick(offset: 275, at: 10.125) == true)
        // 276pt in 0.125 s = 2208 pt/s: does not.
        #expect(driver.scrollTick(offset: 551, at: 10.25) == false)
    }

    /// The velocity is measured since the last tick that reconciled, not the
    /// last tick at all: a throttled tick does not move the sample.
    @Test func aThrottledTickDoesNotMoveTheVelocitySample() {
        var driver = ForYouGridAutoplayDriver()
        _ = driver.scrollTick(offset: 0, at: 10)
        #expect(driver.scrollTick(offset: 1000, at: 10.01) == nil)
        // 150pt since the sample at 10.0, over a tenth of a second.
        #expect(driver.scrollTick(offset: 150, at: 10.1) == true)
    }

    @Test func scrollingBackUpIsMeasuredAsFastAsScrollingDown() {
        var driver = ForYouGridAutoplayDriver()
        _ = driver.scrollTick(offset: 1000, at: 10)
        #expect(driver.scrollTick(offset: 600, at: 10.1) == false)
    }
}
