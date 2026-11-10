import Testing
import UIKit
@testable import Feed

/// The comments sheet's height on TODAY's catalogue: one per shape (#2184,
/// #2195, the owner 2026-11-08). A portrait media shrinks into the room above
/// a sheet of 60 % to 75 % of the screen; a square, 4:3 or 16:9 one keeps the
/// screen's whole width, less its side margins, and the sheet takes exactly
/// what is left — never under its minimum.
///
/// ⚠️ These pin today's numbers (the four heights on a 17 Pro Max and an
/// iPhone SE): change the catalogue or `CommentsSheetLayout`, and these are
/// the tests to update, with `CommentsSheetCutTests`. The rules any catalogue
/// keeps are `CommentsSheetCatalogueTests`'.
@MainActor
struct CommentsSheetRestingHeightTests {
    private typealias Session = SnapCommentsSheetSession
    private let layout = CommentsSheetLayout.standard

    /// An iPhone 17 Pro Max's window, and an iPhone SE's.
    private static let proMax = (CGSize(width: 440, height: 956), UIEdgeInsets(top: 62, left: 0, bottom: 34, right: 0))
    private static let se = (CGSize(width: 375, height: 667), UIEdgeInsets(top: 20, left: 0, bottom: 0, right: 0))

    private func resting(
        _ picture: CGSize, on screen: (CGSize, UIEdgeInsets) = proMax
    ) -> CGFloat {
        Session.restingHeight(screen: screen.0, safeArea: screen.1, picture: picture)
    }

    /// The share of the screen the sheet takes over a `width` × `height`
    /// picture.
    private func share(_ width: CGFloat, _ height: CGFloat, on screen: (CGSize, UIEdgeInsets) = proMax) -> CGFloat {
        resting(cut(width, height), on: screen) / screen.0.height
    }

    /// The room the media is left above a sheet of `height`.
    private func room(above height: CGFloat, on screen: (CGSize, UIEdgeInsets) = proMax) -> CGFloat {
        screen.0.height - screen.1.bottom - height - layout.mediaGap - screen.1.top
    }

    private func fullWidth(on screen: (CGSize, UIEdgeInsets) = proMax) -> CGFloat {
        screen.0.width - 2 * layout.mediaSideMargin
    }

    /// The picture the sheet is handed: the page's picture, cut.
    private func cut(_ width: CGFloat, _ height: CGFloat) -> CGSize {
        SnapFeedCell.commentsSheetCut(of: CGRect(x: 0, y: 0, width: width, height: height)).size
    }

    // MARK: - The four heights, on a 17 Pro Max

    @Test func aPortraitMediaGetsTheFloor() {
        for picture in [cut(1080, 1920), cut(800, 1000), cut(750, 1000)] {
            #expect(resting(picture) == 956 * layout.floorShare)
        }
    }

    /// 16:9 ≈ 64 % (its media 424 × 239), 4:3 ≈ 56 % (424 × 318), square
    /// ≈ 45 % (424 × 424), portrait 60 %.
    @Test func theFourHeightsOnAProMax() {
        #expect(abs(share(1080, 1920) - 0.60) < 0.005, "portrait \(share(1080, 1920))")
        #expect(abs(share(1280, 720) - 0.641) < 0.005, "16:9 \(share(1280, 720))")
        #expect(abs(share(960, 720) - 0.558) < 0.005, "4:3 \(share(960, 720))")
        #expect(abs(share(1000, 1000) - 0.448) < 0.005, "square \(share(1000, 1000))")
    }

    @Test func aFullWidthMediaKeepsTheWholeWidth() {
        for (width, height) in [(1000.0, 1000.0), (960, 720), (1280, 720)] as [(CGFloat, CGFloat)] {
            let picture = cut(width, height)
            let media = fullWidth() * picture.height / picture.width
            #expect(abs(room(above: resting(picture)) - media) < 0.5, "\(width) × \(height) was shrunk")
        }
    }

    /// Every ratio a shape gathers lands on its ONE height: a 3:2 photo and
    /// a 5:4 one on 4:3's.
    @Test func everyRatioOfAShapeGetsItsHeight() {
        let fourThree = resting(cut(960, 720))
        for picture in [cut(900, 600), cut(1250, 1000), cut(1440, 1080)] {
            #expect(abs(resting(picture) - fourThree) < 3, "\(picture)")
        }
    }

    /// Four heights, apart.
    @Test func theFourHeightsStandApart() {
        let heights = [cut(1080, 1920), cut(1000, 1000), cut(960, 720), cut(1280, 720)].map { resting($0) }
        #expect(Set(heights.map { Int($0.rounded()) }).count == 4, "\(heights)")
        // 16:9 > portrait > 4:3 > square.
        #expect(heights[3] > heights[0] && heights[0] > heights[2] && heights[2] > heights[1], "\(heights)")
    }

    // MARK: - On an iPhone SE

    /// 16:9 ≈ 65 %, 4:3 ≈ 55 %, portrait 60 %, and the square at the
    /// minimum sheet.
    @Test func theFourHeightsOnAnSE() {
        #expect(abs(share(1080, 1920, on: Self.se) - 0.60) < 0.005)
        #expect(abs(share(1280, 720, on: Self.se) - 0.655) < 0.005, "\(share(1280, 720, on: Self.se))")
        #expect(abs(share(960, 720, on: Self.se) - 0.553) < 0.005, "\(share(960, 720, on: Self.se))")
    }

    /// A full-width square would leave an SE about 280 pt: the sheet stops at
    /// its minimum, and the media shrinks to fit.
    @Test func anSESquareStopsAtTheMinimumSheet() {
        let height = resting(cut(1000, 1000), on: Self.se)
        #expect(height == layout.minimumSheetHeight)
        #expect(room(above: height, on: Self.se) < fullWidth(on: Self.se), "the media did not shrink")
    }

    @Test func anSELandscapeKeepsItsWholeWidth() {
        for (width, height) in [(960.0, 720.0), (1280, 720)] as [(CGFloat, CGFloat)] {
            let picture = cut(width, height)
            let sheet = resting(picture, on: Self.se)
            #expect(sheet > layout.minimumSheetHeight)
            let media = fullWidth(on: Self.se) * picture.height / picture.width
            #expect(abs(room(above: sheet, on: Self.se) - media) < 0.5)
        }
    }

    // MARK: - The edges

    @Test func aWidePanoramaStaysUnderTheCeiling() {
        #expect(resting(cut(8000, 1000)) <= 956 * layout.ceilingShare)
    }

    @Test func noPictureYetGetsTheFloor() {
        #expect(resting(.zero) == 956 * layout.floorShare)
    }

    // MARK: - The expanded detent

    /// No expanded detent for square, 4:3 and 16:9, however many comments;
    /// portrait keeps it.
    @Test func onlyAPortraitMediaOffersTheExpandedDetent() {
        #expect(Session.offersExpandedDetent(picture: cut(1080, 1920)))
        #expect(Session.offersExpandedDetent(picture: cut(800, 1000)))
        #expect(!Session.offersExpandedDetent(picture: cut(1000, 1000)))
        #expect(!Session.offersExpandedDetent(picture: cut(960, 720)))
        #expect(!Session.offersExpandedDetent(picture: cut(1280, 720)))
        #expect(!Session.offersExpandedDetent(picture: cut(4000, 1000)))
        #expect(Session.offersExpandedDetent(picture: .zero), "a picture not known yet keeps the shrinking sheet")
    }
}
