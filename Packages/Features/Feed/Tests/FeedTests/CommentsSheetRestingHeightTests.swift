import Testing
import UIKit
@testable import Feed

/// The comments sheet's resting height: one per shape (#2184, the owner,
/// 2026-11-07). A portrait media shrinks into the room above a sheet of 60 %
/// to 75 % of the screen; a square or landscape one keeps the screen's whole
/// width, less its side margins, and the sheet takes exactly what is left —
/// never under its minimum.
@MainActor
struct CommentsSheetRestingHeightTests {
    private typealias Session = SnapCommentsSheetSession

    /// An iPhone 17 Pro Max's window, and an iPhone SE's.
    private static let proMax = (CGSize(width: 440, height: 956), UIEdgeInsets(top: 62, left: 0, bottom: 34, right: 0))
    private static let se = (CGSize(width: 375, height: 667), UIEdgeInsets(top: 20, left: 0, bottom: 0, right: 0))

    private func resting(
        _ picture: CGSize, on screen: (CGSize, UIEdgeInsets) = proMax
    ) -> CGFloat {
        Session.restingHeight(screen: screen.0, safeArea: screen.1, picture: picture)
    }

    /// The room the media is left above a sheet of `height`.
    private func room(above height: CGFloat, on screen: (CGSize, UIEdgeInsets) = proMax) -> CGFloat {
        screen.0.height - screen.1.bottom - height - Session.mediaGap - screen.1.top
    }

    private func fullWidth(on screen: (CGSize, UIEdgeInsets) = proMax) -> CGFloat {
        screen.0.width - 2 * Session.mediaSideMargin
    }

    /// The picture the sheet is handed: the page's picture, cut.
    private func cut(_ width: CGFloat, _ height: CGFloat) -> CGSize {
        SnapFeedCell.commentsSheetCut(of: CGRect(x: 0, y: 0, width: width, height: height)).size
    }

    // MARK: - The three heights

    @Test func aPortraitMediaGetsTheFloor() {
        for picture in [cut(1080, 1920), cut(800, 1000), cut(750, 1000)] {
            #expect(resting(picture) == 956 * Session.floorShare)
        }
    }

    @Test func aSquareMediaKeepsTheWholeWidth() {
        let height = resting(cut(1000, 1000))
        #expect(abs(room(above: height) - fullWidth()) < 0.5, "the square was shrunk")
        // ≈ 45 % of a 17 Pro Max.
        #expect(abs(height / 956 - 0.448) < 0.01, "\(height / 956)")
    }

    @Test func aLandscapeMediaKeepsTheWholeWidth() {
        let height = resting(cut(1280, 720))
        #expect(abs(room(above: height) - fullWidth() * 3 / 4) < 0.5, "the 16:9 clip was shrunk")
        // ≈ 56 % of a 17 Pro Max.
        #expect(abs(height / 956 - 0.559) < 0.01, "\(height / 956)")
    }

    /// Every landscape ratio the cut reaches lands on ONE height.
    @Test func everyLandscapeRatioGetsOneHeight() {
        let heights = [cut(1280, 720), cut(900, 600), cut(960, 720)].map { resting($0) }
        // 4:3 loses its trimmed sides too: within a few points.
        #expect(heights.max()! - heights.min()! < 3, "\(heights)")
    }

    /// Three heights, side by side.
    @Test func theThreeHeightsStandApart() {
        let portrait = resting(cut(1080, 1920))
        let landscape = resting(cut(1280, 720))
        let square = resting(cut(1000, 1000))
        #expect(portrait > landscape && landscape > square)
    }

    // MARK: - Small screens

    /// A full-width square would leave an SE about 280 pt: the sheet stops at
    /// its minimum, and the media shrinks to fit.
    @Test func anSESquareStopsAtTheMinimumSheet() {
        let height = resting(cut(1000, 1000), on: Self.se)
        #expect(height == Session.minimumSheetHeight)
        #expect(room(above: height, on: Self.se) < fullWidth(on: Self.se), "the media did not shrink")
    }

    @Test func anSELandscapeKeepsItsWholeWidth() {
        let height = resting(cut(1280, 720), on: Self.se)
        #expect(height > Session.minimumSheetHeight)
        #expect(abs(room(above: height, on: Self.se) - fullWidth(on: Self.se) * 3 / 4) < 0.5)
    }

    // MARK: - The edges

    @Test func aWidePanoramaStaysUnderTheCeiling() {
        #expect(resting(cut(8000, 1000)) <= 956 * Session.ceilingShare)
    }

    @Test func noPictureYetGetsTheFloor() {
        #expect(resting(.zero) == 956 * Session.floorShare)
    }

    // MARK: - The expanded detent

    /// No expanded detent for square and landscape, however many comments;
    /// portrait keeps it.
    @Test func onlyAPortraitMediaOffersTheExpandedDetent() {
        #expect(Session.offersExpandedDetent(picture: cut(1080, 1920)))
        #expect(Session.offersExpandedDetent(picture: cut(800, 1000)))
        #expect(!Session.offersExpandedDetent(picture: cut(1000, 1000)))
        #expect(!Session.offersExpandedDetent(picture: cut(1280, 720)))
        #expect(!Session.offersExpandedDetent(picture: cut(4000, 1000)))
        #expect(Session.offersExpandedDetent(picture: .zero), "a picture not known yet keeps today's sheet")
    }
}
