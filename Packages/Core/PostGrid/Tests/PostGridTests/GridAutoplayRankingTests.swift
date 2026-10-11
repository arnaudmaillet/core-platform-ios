import CoreModels
import Foundation
import Testing
import UIKit
@testable import PostGrid

/// The autoplay ranking the For You grid, the profile gallery and the For You
/// rails share (#861), without a collection view, a window or a clock.
@MainActor
struct GridAutoplayRankingTests {
    private static let clip = URL(string: "https://media.test/clip.m3u8")!
    /// A vertical band 400pt tall from y 100 to 500, centred on y 300.
    private static let column = CGRect(x: 0, y: 100, width: 390, height: 400)
    /// A horizontal row's band in its content space: x 200 to 590.
    private static let row = CGRect(x: 200, y: 0, width: 390, height: 200)

    /// A cell is only carried through to the coordinator; nothing is drawn.
    private func tile(_ id: String, media: CGRect, paused: Bool = false) -> GridAutoplayRanking.Tile {
        .init(
            id: PostID(id), url: Self.clip,
            cell: PostGridTileCell(frame: CGRect(origin: .zero, size: media.size)),
            mediaFrame: media, isPaused: paused
        )
    }

    private func brick(_ id: String, minY: CGFloat, paused: Bool = false) -> GridAutoplayRanking.Tile {
        tile(id, media: CGRect(x: 0, y: minY, width: 130, height: 100), paused: paused)
    }

    private func card(_ id: String, minX: CGFloat) -> GridAutoplayRanking.Tile {
        tile(id, media: CGRect(x: minX, y: 0, width: 150, height: 200))
    }

    // MARK: - Distance

    @Test func aVerticalGridMeasuresFromTheViewportsCentreToTheMediasCentre() {
        let media = CGRect(x: 0, y: 120, width: 130, height: 100)
        #expect(GridAutoplayRanking.distance(of: media, in: Self.column, from: .verticalCentre) == 130)
    }

    @Test func aVerticalDistanceIsTheSameAboveAndBelowTheCentre() {
        let above = CGRect(x: 0, y: 120, width: 130, height: 100)
        let below = CGRect(x: 0, y: 380, width: 130, height: 100)
        #expect(GridAutoplayRanking.distance(of: above, in: Self.column, from: .verticalCentre)
            == GridAutoplayRanking.distance(of: below, in: Self.column, from: .verticalCentre))
    }

    @Test func aVerticalDistanceIgnoresWhereTheMediaSitsAcross() {
        let left = CGRect(x: 0, y: 250, width: 130, height: 100)
        let right = CGRect(x: 260, y: 250, width: 130, height: 100)
        #expect(GridAutoplayRanking.distance(of: left, in: Self.column, from: .verticalCentre) == 0)
        #expect(GridAutoplayRanking.distance(of: right, in: Self.column, from: .verticalCentre) == 0)
    }

    @Test func aHorizontalRowMeasuresFromTheViewportsLeftEdgeToTheMediasLeftEdge() {
        let media = CGRect(x: 360, y: 0, width: 150, height: 200)
        #expect(GridAutoplayRanking.distance(of: media, in: Self.row, from: .minXEdge) == 160)
    }

    @Test func aCardStartingJustLeftOfTheLeftEdgeIsStillCloseToIt() {
        let media = CGRect(x: 170, y: 0, width: 150, height: 200)
        #expect(GridAutoplayRanking.distance(of: media, in: Self.row, from: .minXEdge) == 30)
    }

    @Test func aHorizontalDistanceIgnoresWhereTheMediaSitsDown() {
        let media = CGRect(x: 200, y: 500, width: 150, height: 200)
        #expect(GridAutoplayRanking.distance(of: media, in: Self.row, from: .minXEdge) == 0)
    }

    // MARK: - Candidates

    @Test func aTileExactlyHalfInsideTheViewportIsAdmitted() {
        // 50 of 100pt inside.
        let candidates = GridAutoplayRanking.candidates(
            from: [brick("edge", minY: 50)], in: Self.column, reference: .verticalCentre
        )
        #expect(candidates.map(\.id) == [PostID("edge")])
    }

    @Test func aTileLessThanHalfInsideIsNotAdmitted() {
        // 40 of 100pt inside.
        let candidates = GridAutoplayRanking.candidates(
            from: [brick("creeping", minY: 460)], in: Self.column, reference: .verticalCentre
        )
        #expect(candidates.isEmpty)
    }

    @Test func aCardLessThanHalfInsideARowIsNotAdmitted() {
        // 60 of 150pt inside, past the trailing edge at x 590.
        let candidates = GridAutoplayRanking.candidates(
            from: [card("peeking", minX: 530)], in: Self.row, reference: .minXEdge
        )
        #expect(candidates.isEmpty)
    }

    @Test func aNullViewportAdmitsNothing() {
        let candidates = GridAutoplayRanking.candidates(
            from: [card("any", minX: 200)], in: .null, reference: .minXEdge
        )
        #expect(candidates.isEmpty)
    }

    @Test func aVerticalGridRanksItsCandidatesByDistanceFromTheCentre() {
        let candidates = GridAutoplayRanking.candidates(
            from: [brick("centred", minY: 250), brick("above", minY: 120), brick("below", minY: 380)],
            in: Self.column, reference: .verticalCentre
        )
        #expect(candidates.map(\.distanceFromCentre) == [0, 130, 130])
    }

    @Test func aRowRanksItsCandidatesByDistanceFromTheLeftEdge() {
        let candidates = GridAutoplayRanking.candidates(
            from: [card("first", minX: 200), card("second", minX: 360)],
            in: Self.row, reference: .minXEdge
        )
        #expect(candidates.map(\.distanceFromCentre) == [0, 160])
    }

    @Test func admittedTilesKeepTheOrderTheyCameIn() {
        let candidates = GridAutoplayRanking.candidates(
            from: [brick("b", minY: 380), brick("off", minY: 900), brick("a", minY: 250)],
            in: Self.column, reference: .verticalCentre
        )
        #expect(candidates.map(\.id) == [PostID("b"), PostID("a")])
    }

    @Test func aPausedTileIsHandedOverPausedAndAnAdvancingOneIsNot() {
        let candidates = GridAutoplayRanking.candidates(
            from: [brick("peeking", minY: 250, paused: true), brick("watched", minY: 120)],
            in: Self.column, reference: .verticalCentre
        )
        #expect(candidates.map(\.isPaused) == [true, false])
    }

    @Test func theCellAndTheStreamAreCarriedThrough() {
        let measured = brick("carried", minY: 250)
        let candidate = GridAutoplayRanking.candidates(
            from: [measured], in: Self.column, reference: .verticalCentre
        ).first
        #expect(candidate?.url == Self.clip)
        #expect(candidate?.cell === measured.cell)
    }

    // MARK: - Budget

    @Test func aMosaicPlaysSixAndATimelineFive() {
        #expect(GridAutoplayRanking.concurrentPlayers(isMosaic: true) == 6)
        #expect(GridAutoplayRanking.concurrentPlayers(isMosaic: false) == 5)
    }

    @Test func theBudgetIsTheShapesNumberWhenTheLeadHoldsNothing() {
        #expect(GridAutoplayRanking.playerBudget(concurrentPlayers: 5, poolCapacity: 6, reserve: 0) == 5)
    }

    @Test func aLeadsPlayersComeOutOfTheSurfacesShare() {
        #expect(GridAutoplayRanking.playerBudget(concurrentPlayers: 5, poolCapacity: 6, reserve: 3) == 3)
        #expect(GridAutoplayRanking.playerBudget(concurrentPlayers: 6, poolCapacity: 6, reserve: 1) == 5)
    }

    @Test func aLeadHoldingMoreThanThePoolLeavesNothingRatherThanANegativeBudget() {
        #expect(GridAutoplayRanking.playerBudget(concurrentPlayers: 5, poolCapacity: 6, reserve: 9) == 0)
    }

    @Test func aLargerPoolNeverLiftsTheShapesCeiling() {
        #expect(GridAutoplayRanking.playerBudget(concurrentPlayers: 6, poolCapacity: 12, reserve: 0) == 6)
    }

    @Test func aSurfaceHoldsAsManyPlayersAsItHasCandidatesUpToItsBudget() {
        #expect(GridAutoplayRanking.playersHeld(candidateCount: 0, budget: 3) == 0)
        #expect(GridAutoplayRanking.playersHeld(candidateCount: 2, budget: 3) == 2)
        #expect(GridAutoplayRanking.playersHeld(candidateCount: 5, budget: 3) == 3)
    }

    // MARK: - Fling gate

    @Test func theSampledSpeedIsTheDistanceOverTheInterval() {
        // 150pt in an eighth of a second.
        #expect(GridAutoplayRanking.sampledSpeed(from: 0, to: 150, over: 0.125) == 1200)
    }

    @Test func scrollingBackIsMeasuredAsFastAsScrollingForward() {
        #expect(GridAutoplayRanking.sampledSpeed(from: 1000, to: 850, over: 0.125) == 1200)
    }

    @Test func noElapsedTimeMeansNoSpeed() {
        #expect(GridAutoplayRanking.sampledSpeed(from: 0, to: 500, over: 0) == 0)
    }

    @Test func aHandDragStartsPlayersAndAHardFlingDoesNot() {
        #expect(GridAutoplayRanking.allowsStarts(atVelocity: 1500))
        #expect(!GridAutoplayRanking.allowsStarts(atVelocity: 4000))
    }

    @Test func theGateSitsAtExactlyTheMaximumStartVelocity() {
        #expect(GridAutoplayRanking.maximumStartVelocity == 2200)
        #expect(GridAutoplayRanking.allowsStarts(atVelocity: 2200))
        #expect(!GridAutoplayRanking.allowsStarts(atVelocity: CGFloat(2200).nextUp))
    }

    /// A pan gesture reports a signed velocity; scrolling up is as fast as
    /// scrolling down.
    @Test func aNegativeVelocityIsGatedOnItsMagnitude() {
        #expect(GridAutoplayRanking.allowsStarts(atVelocity: -2200))
        #expect(!GridAutoplayRanking.allowsStarts(atVelocity: -4000))
    }

    @Test func aSurfaceMayPassItsOwnThreshold() {
        #expect(!GridAutoplayRanking.allowsStarts(atVelocity: 1500, maximum: 1000))
    }
}
