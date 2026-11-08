import Testing
import UIKit
@testable import Feed

/// The part of a picture the comments sheet shows (#2184, the owner,
/// 2026-11-07): every picture sorted into one of three shapes — portrait,
/// square, landscape — and cut to it, centred, by a quarter of the dimension
/// it cuts at most.
@MainActor
struct CommentsSheetCutTests {
    typealias Shape = SnapFeedCell.CommentsSheetShape

    private func cut(_ width: CGFloat, _ height: CGFloat) -> CGRect {
        SnapFeedCell.commentsSheetCut(of: CGRect(x: -10, y: 20, width: width, height: height))
    }

    private func ratio(_ rect: CGRect) -> CGFloat { rect.width / rect.height }

    // MARK: - The shapes

    @Test(arguments: [
        (9.0, 16.0, Shape.portrait), (2, 3, .portrait), (3, 4, .portrait), (4, 5, .portrait),
        (1, 1, .square), (5, 4, .landscape), (4, 3, .landscape), (3, 2, .landscape), (16, 9, .landscape),
        (4, 1, .landscape), (9, 10, .square), (11, 10, .square),
    ] as [(CGFloat, CGFloat, Shape)])
    func eachRatioHasItsShape(_ width: CGFloat, _ height: CGFloat, _ shape: Shape) {
        #expect(Shape.of(CGSize(width: width, height: height)) == shape)
    }

    /// The thresholds are the midpoints between the shapes.
    @Test func theThresholdsAreTheMidpoints() {
        #expect(abs(Shape.squareFrom - 0.866) < 0.001)
        #expect(abs(Shape.landscapeFrom - 1.155) < 0.001)
        #expect(Shape.of(CGSize(width: 0.86, height: 1)) == .portrait)
        #expect(Shape.of(CGSize(width: 0.87, height: 1)) == .square)
        #expect(Shape.of(CGSize(width: 1.15, height: 1)) == .square)
        #expect(Shape.of(CGSize(width: 1.16, height: 1)) == .landscape)
        #expect(Shape.of(.zero) == nil)
    }

    // MARK: - The cuts

    @Test func aNineSixteenClipIsCutToThreeFourExactly() {
        let shown = cut(450, 800)
        #expect(abs(ratio(shown) - 0.75) < 0.001)
        #expect(shown.width == 450)
        // An eighth off the top, an eighth off the bottom, centred.
        #expect(abs(shown.minY - (20 + 100)) < 0.001)
        #expect(abs(shown.maxY - (820 - 100)) < 0.001)
    }

    @Test func aSixteenNineClipIsCutToFourThreeExactly() {
        let shown = cut(1280, 720)
        #expect(abs(ratio(shown) - 4.0 / 3.0) < 0.001)
        #expect(shown.height == 720)
        // An eighth off each side, centred.
        #expect(abs(shown.minX - (-10 + 160)) < 0.001)
        #expect(abs(shown.width - 960) < 0.001)
    }

    /// A 4:5 photo is a portrait: it loses 6 % of its width, not its height.
    @Test func aFourFivePhotoLosesSixPercentOfItsWidth() {
        let shown = cut(800, 1000)
        #expect(abs(ratio(shown) - 0.75) < 0.001)
        #expect(shown.height == 1000)
        #expect(abs(shown.width - 750) < 0.001)
        #expect(abs(shown.midX - (-10 + 400)) < 0.001)
    }

    @Test func aTwoThreePhotoIsCutToThreeFour() {
        #expect(abs(ratio(cut(600, 900)) - 0.75) < 0.001)
    }

    @Test func aThreeTwoPhotoIsCutToFourThree() {
        #expect(abs(ratio(cut(900, 600)) - 4.0 / 3.0) < 0.001)
    }

    @Test(arguments: [(900.0, 1000.0), (1000.0, 1000.0), (1100.0, 1000.0)] as [(CGFloat, CGFloat)])
    func aNearSquareIsCutToSquare(_ width: CGFloat, _ height: CGFloat) {
        #expect(abs(ratio(cut(width, height)) - 1) < 0.01)
    }

    @Test func aThreeFourPictureStaysWhole() {
        let whole = CGRect(x: -10, y: 20, width: 750, height: 1000)
        #expect(SnapFeedCell.commentsSheetCut(of: whole) == whole)
    }

    // MARK: - The quarter

    @Test func aTallerPictureLosesAQuarterOfItsHeightAtMost() {
        let shown = cut(400, 1000)
        #expect(abs(shown.height - 750) < 0.001)
        #expect(ratio(shown) < 0.75)
    }

    @Test func aPanoramaLosesAQuarterOfItsWidthAtMost() {
        let shown = cut(4000, 1000)
        #expect(abs(shown.width - 3000) < 0.001)
        #expect(shown.height == 1000)
        #expect(ratio(shown) > 4.0 / 3.0)
    }

    /// A picture wider than tall that the shape barely cuts still loses its
    /// trimmed sides (the owner, 2026-11-03: a dark sliver baked into a clip).
    @Test func aFourThreePictureLosesItsTrimmedSides() {
        let shown = cut(960, 720)
        #expect(shown.height == 720)
        #expect(abs(shown.width - (960 - 2 * SnapFeedCell.landscapeSideTrim)) < 0.001)
    }
}
