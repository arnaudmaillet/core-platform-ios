import Testing
import UIKit
@testable import Feed

/// The comments sheet's tallest resting height follows the media's shape
/// (#2087, the owner, 2026-11-03): the media keeps the screen's width, less
/// its side margins, above it; the sheet takes the rest, between a floor —
/// lower for a square to landscape media — and a ceiling.
@MainActor
struct CommentsSheetRestingHeightTests {
    /// An iPhone 18 Pro's window.
    private let screen = CGSize(width: 402, height: 874)
    private let safeArea = UIEdgeInsets(top: 62, left: 0, bottom: 34, right: 0)

    private func resting(_ picture: CGSize) -> CGFloat {
        SnapCommentsSheetSession.restingHeight(screen: screen, safeArea: safeArea, picture: picture)
    }

    /// The room the media is left above a sheet of `height`.
    private func room(above height: CGFloat) -> CGFloat {
        screen.height - safeArea.bottom - height - SnapCommentsSheetSession.mediaGap - safeArea.top
    }

    @Test func aLandscapeMediaKeepsTheScreensWidth() {
        let height = resting(CGSize(width: 1280, height: 720))
        #expect(height > screen.height * SnapCommentsSheetSession.floorShare)
        #expect(height < screen.height * SnapCommentsSheetSession.ceilingShare)
        let width = screen.width - 2 * SnapCommentsSheetSession.mediaSideMargin
        #expect(abs(room(above: height) - width * 720 / 1280) < 0.5)
    }

    @Test func aFullScreenPortraitMediaGetsTheFloor() {
        #expect(resting(screen) == screen.height * SnapCommentsSheetSession.floorShare)
    }

    @Test func aFourThreeMediaKeepsTheScreensWidthUnderTheUsualFloor() {
        let height = resting(CGSize(width: 960, height: 720))
        #expect(height < screen.height * SnapCommentsSheetSession.floorShare)
        #expect(height > screen.height * SnapCommentsSheetSession.wideFloorShare)
        let width = screen.width - 2 * SnapCommentsSheetSession.mediaSideMargin
        #expect(abs(room(above: height) - width * 720 / 960) < 0.5)
    }

    @Test func aSquareMediaGetsTheWideFloor() {
        #expect(resting(CGSize(width: 402, height: 402)) == screen.height * SnapCommentsSheetSession.wideFloorShare)
    }

    @Test func aPortraitFittedMediaGetsTheFloor() {
        #expect(resting(CGSize(width: 716, height: 934)) == screen.height * SnapCommentsSheetSession.floorShare)
    }

    @Test func aPanoramaStopsAtTheCeiling() {
        #expect(resting(CGSize(width: 4000, height: 1000)) == screen.height * SnapCommentsSheetSession.ceilingShare)
    }

    @Test func noPictureYetGetsTheFloor() {
        #expect(resting(.zero) == screen.height * SnapCommentsSheetSession.floorShare)
    }
}
