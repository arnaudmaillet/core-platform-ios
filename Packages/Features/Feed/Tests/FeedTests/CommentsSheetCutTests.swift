import Testing
import UIKit
@testable import Feed

/// The part of a picture the comments sheet shows, on TODAY's catalogue
/// (#2184, #2195, the owner 2026-11-08): every picture sorted BY RATIO into
/// one of four shapes — 3:4, 1:1, 4:3, 16:9 — and cut to it, centred, by a
/// quarter of the dimension it cuts at most.
///
/// ⚠️ These pin today's numbers: change the catalogue, and these are the
/// tests to update (with `CommentsSheetRestingHeightTests`). The rules any
/// catalogue keeps are `CommentsSheetCatalogueTests`', which need no change.
@MainActor
struct CommentsSheetCutTests {
    private typealias Shape = CommentsSheetShape

    private func cut(_ width: CGFloat, _ height: CGFloat) -> CGRect {
        SnapFeedCell.commentsSheetCut(of: CGRect(x: -10, y: 20, width: width, height: height))
    }

    private func ratio(_ rect: CGRect) -> CGFloat { rect.width / rect.height }

    /// The shape's name a picture of `width` × `height` takes.
    private func shape(_ width: CGFloat, _ height: CGFloat) -> String? {
        Shape.of(CGSize(width: width, height: height))?.name
    }

    private var trim: CGFloat { CommentsSheetLayout.standard.landscapeSideTrim }

    // MARK: - The four shapes

    @Test func theCatalogueIsTodays() {
        #expect(Shape.standardCatalogue.map(\.name) == ["3:4", "1:1", "4:3", "16:9"])
        #expect(Shape.isValid(Shape.standardCatalogue))
    }

    @Test(arguments: [
        (9.0, 16.0, "3:4"), (2, 3, "3:4"), (3, 4, "3:4"), (4, 5, "3:4"),
        (9, 10, "1:1"), (1, 1, "1:1"), (11, 10, "1:1"),
        (5, 4, "4:3"), (4, 3, "4:3"), (3, 2, "4:3"),
        (16, 9, "16:9"), (2, 1, "16:9"), (4, 1, "16:9"),
    ] as [(CGFloat, CGFloat, String)])
    func eachRatioHasItsShape(_ width: CGFloat, _ height: CGFloat, _ name: String) {
        #expect(shape(width, height) == name)
    }

    /// The thresholds are the geometric midpoints between neighbours:
    /// √(3/4), √(4/3) and √(4/3 × 16/9).
    @Test func theThresholdsAreTheMidpoints() {
        let thresholds = Shape.thresholds(of: Shape.standardCatalogue)
        #expect(thresholds.count == 3)
        #expect(abs(thresholds[0] - 0.866) < 0.001)
        #expect(abs(thresholds[1] - 1.155) < 0.001)
        #expect(abs(thresholds[2] - 1.540) < 0.001)
        #expect(shape(0.865, 1) == "3:4")
        #expect(shape(0.867, 1) == "1:1")
        #expect(shape(1.154, 1) == "1:1")
        #expect(shape(1.156, 1) == "4:3")
        #expect(shape(1.539, 1) == "4:3")
        #expect(shape(1.541, 1) == "16:9")
        #expect(Shape.of(.zero) == nil)
    }

    /// By ratio, not by kind: a 4:3 clip keeps 4:3, a 16:9 photo 16:9.
    @Test func theShapeIsTheRatiosNotTheKinds() {
        #expect(shape(1440, 1080) == "4:3", "a 4:3 clip")
        #expect(shape(4032, 3024) == "4:3", "a phone photo")
        #expect(shape(1920, 1080) == "16:9", "a 16:9 clip")
        #expect(shape(4000, 2250) == "16:9", "a 16:9 photo")
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

    /// A 16:9 clip is a shape of its own now (#2195): it loses only its
    /// trimmed sides, against a quarter of its width under #2184.
    @Test func aSixteenNineClipIsUncut() {
        let shown = cut(1280, 720)
        #expect(shown.height == 720)
        #expect(abs(shown.width - (1280 - 2 * trim)) < 0.001)
        #expect(abs(shown.midX - (-10 + 640)) < 0.001)
    }

    /// A 4:3 picture — a phone photo, or a 4:3 clip — loses only its trimmed
    /// sides (the owner, 2026-11-03: a dark sliver baked into a clip).
    @Test func aFourThreePictureIsUncut() {
        for (width, height) in [(960.0, 720.0), (1440, 1080)] as [(CGFloat, CGFloat)] {
            let shown = cut(width, height)
            #expect(shown.height == height)
            #expect(abs(shown.width - (width - 2 * trim)) < 0.001)
        }
    }

    /// A 3:2 photo becomes 4:3: it loses 11 % of its width.
    @Test func aThreeTwoPhotoLosesElevenPercentOfItsWidth() {
        let shown = cut(900, 600)
        #expect(abs(ratio(shown) - 4.0 / 3.0) < 0.001)
        #expect(shown.height == 600)
        #expect(abs(1 - shown.width / 900 - 0.111) < 0.001)
    }

    /// A 4:5 photo is a portrait: it loses 6 % of its width, not its height.
    @Test func aFourFivePhotoLosesSixPercentOfItsWidth() {
        let shown = cut(800, 1000)
        #expect(abs(ratio(shown) - 0.75) < 0.001)
        #expect(shown.height == 1000)
        #expect(abs(shown.width - 750) < 0.001)
        #expect(abs(shown.midX - (-10 + 400)) < 0.001)
    }

    @Test(arguments: [(900.0, 1000.0), (1000.0, 1000.0), (1100.0, 1000.0)] as [(CGFloat, CGFloat)])
    func aNearSquareIsCutToSquare(_ width: CGFloat, _ height: CGFloat) {
        #expect(abs(ratio(cut(width, height)) - 1) < 0.01)
    }

    @Test func aThreeFourPictureStaysWhole() {
        let whole = CGRect(x: -10, y: 20, width: 750, height: 1000)
        #expect(SnapFeedCell.commentsSheetCut(of: whole) == whole)
    }

    /// The worst cut within the catalogue is about 13 %, on either side of
    /// the 4:3 / 16:9 threshold — against 25 % under #2184.
    @Test func theWorstCutIsAboutThirteenPercent() {
        let threshold = Shape.thresholds(of: Shape.standardCatalogue)[2]
        let under = cut(1000 * threshold * 0.9999, 1000)
        let over = cut(1000 * threshold * 1.0001, 1000)
        #expect(abs(1 - under.width / (1000 * threshold * 0.9999) - 0.134) < 0.002)
        #expect(abs(1 - over.height / 1000 - 0.134) < 0.002)
    }

    // MARK: - The quarter

    @Test func aTallerPictureLosesAQuarterOfItsHeightAtMost() {
        let shown = cut(400, 1000)
        #expect(abs(shown.height - 750) < 0.001)
        #expect(ratio(shown) < 0.75)
    }

    /// A panorama, wider than 16:9, keeps its rest: a quarter of its width
    /// off at most.
    @Test func aPanoramaKeepsItsRest() {
        let shown = cut(4000, 1000)
        #expect(abs(shown.width - 3000) < 0.001)
        #expect(shown.height == 1000)
        #expect(ratio(shown) > 16.0 / 9.0)
    }
}
