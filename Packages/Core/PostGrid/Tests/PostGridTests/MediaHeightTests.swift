import CoreModels
import MediaCore
import UIKit
import Testing
@testable import PostGrid

// A row's preview used to be a fixed 180pt letterbox that aspect-filled
// whatever it was handed, so a 4:5 photo and a 9:16 clip arrived as the same
// horizontal slice of themselves. It now draws the post's OWN shape, clamped at
// both ends — and the clamp is the design: without a ceiling one post fills a
// screen, without a floor an ultra-wide becomes a slit.

@MainActor
private func card(_ width: CGFloat = 390) -> CGFloat { width }

private func height(_ aspect: Double, width: CGFloat = 390) -> CGFloat {
    PostGridListRowCell.mediaHeight(forCardWidth: width, aspectRatio: aspect)
}

private func mediaWidth(_ cardWidth: CGFloat = 390) -> CGFloat {
    cardWidth - PostGridListRowCell.contentInset * 2
}

struct MediaHeightRuleTests {
    /// Between the bounds, the post's own shape is drawn — no crop at all.
    @Test func aShapeInsideTheBoundsIsDrawnAsItIs() {
        #expect(abs(height(4.0 / 3.0) - (mediaWidth() / (4.0 / 3.0)).rounded()) < 0.5)
        #expect(abs(height(1) - mediaWidth().rounded()) < 0.5)
    }

    /// The ceiling: 4:5. A 9:16 story post is cropped to it rather than given
    /// the screen.
    @Test func portraitIsCappedAtFourFifths() {
        let cap = (mediaWidth() * PostGridListRowCell.tallestMediaAspect).rounded()

        #expect(abs(height(4.0 / 5.0) - cap) < 0.5)
        #expect(abs(height(9.0 / 16.0) - cap) < 0.5)
        #expect(abs(height(1.0 / 4.0) - cap) < 0.5)
    }

    /// The floor: 16:9. It matters as much as the ceiling — an unbounded
    /// ultra-wide is a slit with a subject somewhere in it.
    @Test func landscapeIsFlooredAtSixteenNine() {
        let floor = (mediaWidth() / PostGridListRowCell.widestMediaAspect).rounded()

        #expect(abs(height(16.0 / 9.0) - floor) < 0.5)
        #expect(abs(height(21.0 / 9.0) - floor) < 0.5)
        #expect(abs(height(4.0) - floor) < 0.5)
    }

    /// ⚠️ A post the backend never stamped reads as `aspectRatio == 1`, which is
    /// also what SQUARE reads as — `GalleryPost` says so in as many words. It
    /// therefore gets a square preview rather than the old 180pt letterbox.
    ///
    /// Fail-OPEN, and deliberately: a square is a plausible photo and a slit is
    /// not, so an unmeasured post is over-tall rather than mis-cropped. Pinned
    /// because it is a behaviour change for any payload without dimensions, not
    /// because it is obviously right.
    @Test func anUnmeasuredPostGetsASquareRatherThanALetterbox() {
        #expect(abs(height(1) - mediaWidth().rounded()) < 0.5)
        #expect(height(1) > 180)
    }

    /// Nonsense never reaches a constraint. Zero would divide, negative would
    /// invert, and both arrive from a wire this client does not control.
    @Test func aNonsenseRatioIsTreatedAsSquare() {
        #expect(height(0) == height(1))
        #expect(height(-2) == height(1))
    }

    /// Width zero happens: a cell is configured before it is sized, and
    /// `configure` resolves a provisional height off whatever it is carrying.
    @Test func aZeroWidthCardAsksForNoHeight() {
        #expect(height(1, width: 0) == 0)
        #expect(height(1, width: PostGridListRowCell.contentInset * 2) == 0)
    }

    /// The rule is a function of the WIDTH, so the same post is taller on a
    /// wider device — which is what keeps the crop identical across them.
    @Test func theSamePostScalesWithTheCard() {
        #expect(height(4.0 / 5.0, width: 440) > height(4.0 / 5.0, width: 375))
    }
}

@MainActor
struct MediaHeightInRowTests {
    private func row(aspect: Double, width: CGFloat = 390) -> PostGridListRowCell {
        let cell = PostGridListRowCell(frame: CGRect(x: 0, y: 0, width: width, height: 400))
        cell.configure(
            with: GalleryPost(
                id: PostID("p"),
                kind: .photo,
                isRepost: false,
                thumbnailURL: nil,
                aspectRatio: aspect,
                caption: "A caption short enough to leave the card its own shape.",
                publishedAtMS: 0,
                reactionCount: 160
            ),
            imagePipeline: ImagePipeline(fetcher: PlaceholderImageFetcher())
        )
        let attributes = UICollectionViewLayoutAttributes(forCellWith: IndexPath(item: 0, section: 0))
        attributes.frame = cell.frame
        cell.bounds.size.height = cell.preferredLayoutAttributesFitting(attributes).frame.height
        cell.layoutIfNeeded()
        return cell
    }

    /// The point of all of it: two posts of different shapes are two different
    /// rows, where they used to be the same slice.
    @Test func aPortraitRowIsTallerThanALandscapeRow() throws {
        let portrait = try #require(row(aspect: 4.0 / 5.0).mediaHeroRect)
        let landscape = try #require(row(aspect: 16.0 / 9.0).mediaHeroRect)

        #expect(portrait.height > landscape.height)
        #expect(abs(portrait.width - landscape.width) < 0.5)
    }

    /// ⚠️ The height comes from the MODEL, and the measuring pass is where it is
    /// resolved — not `configure`, which runs on a recycled cell's stale width.
    ///
    /// The test asks for a width the cell was never built at: if the height were
    /// resolved at configure time it would answer for 390 and be wrong here.
    @Test func theHeightAnswersForTheWidthTheLayoutGives() throws {
        let cell = PostGridListRowCell(frame: CGRect(x: 0, y: 0, width: 390, height: 400))
        cell.configure(
            with: GalleryPost(
                id: PostID("p"), kind: .photo, isRepost: false, thumbnailURL: nil,
                aspectRatio: 4.0 / 5.0, caption: "Short.", publishedAtMS: 0
            ),
            imagePipeline: ImagePipeline(fetcher: PlaceholderImageFetcher())
        )
        let attributes = UICollectionViewLayoutAttributes(forCellWith: IndexPath(item: 0, section: 0))
        attributes.frame = CGRect(x: 0, y: 0, width: 320, height: 400)
        cell.bounds.size = CGSize(
            width: 320,
            height: cell.preferredLayoutAttributesFitting(attributes).frame.height
        )
        cell.layoutIfNeeded()

        let preview = try #require(cell.mediaHeroRect)
        #expect(abs(preview.height
            - PostGridListRowCell.mediaHeight(forCardWidth: 320, aspectRatio: 4.0 / 5.0)) < 0.5)
    }

    /// And the card still closes at the preview whatever shape it is — the rule
    /// the chips moved onto the media for.
    @Test func aTallCardStillClosesAtItsPreview() throws {
        let cell = row(aspect: 9.0 / 16.0)
        let preview = try #require(cell.mediaHeroRect)

        #expect(abs(cell.bounds.height - preview.maxY - PostGridListRowCell.mediaInset) < 0.5)
    }
}
