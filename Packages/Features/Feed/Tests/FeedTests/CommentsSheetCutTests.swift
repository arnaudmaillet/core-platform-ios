import Testing
import UIKit
@testable import Feed

/// The part of a picture the comments sheet shows (#2087, the owner,
/// 2026-11-04): a picture taller than 3:4 is cut top and bottom towards 3:4,
/// by a quarter of its height at most; 3:4 to square whole; a landscape one
/// less its trimmed sides.
@MainActor
struct CommentsSheetCutTests {
    private func cut(_ width: CGFloat, _ height: CGFloat) -> CGRect {
        SnapFeedCell.commentsSheetCut(of: CGRect(x: -10, y: 20, width: width, height: height))
    }

    private func ratio(_ rect: CGRect) -> CGFloat { rect.width / rect.height }

    @Test func aNineSixteenClipIsCutToThreeFour() {
        let shown = cut(450, 800)
        #expect(abs(ratio(shown) - 0.75) < 0.001)
        #expect(shown.width == 450)
        // An eighth off the top, an eighth off the bottom, centred.
        #expect(abs(shown.minY - (20 + 100)) < 0.001)
        #expect(abs(shown.maxY - (820 - 100)) < 0.001)
    }

    @Test func aTwoThreePhotoIsCutToThreeFour() {
        #expect(abs(ratio(cut(600, 900)) - 0.75) < 0.001)
    }

    @Test func aTallerPictureLosesAQuarterOfItsHeightAtMost() {
        let shown = cut(400, 1000)
        #expect(abs(shown.height - 750) < 0.001)
        #expect(ratio(shown) < 0.75)
    }

    @Test func threeFourToSquareStaysWhole() {
        for (width, height) in [(750.0, 1000.0), (800.0, 1000.0), (1000.0, 1000.0)] {
            let whole = CGRect(x: -10, y: 20, width: width, height: height)
            #expect(SnapFeedCell.commentsSheetCut(of: whole) == whole)
        }
    }

    @Test func aLandscapePictureLosesItsTrimmedSidesOnly() {
        let shown = cut(1280, 720)
        #expect(shown.height == 720)
        #expect(abs(shown.width - (1280 - 2 * SnapFeedCell.landscapeSideTrim)) < 0.001)
    }
}
