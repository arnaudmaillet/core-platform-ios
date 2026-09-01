import CoreModels
import Foundation
import MediaCore
import Testing
import UIKit
@testable import PostGrid

/// The tile a close lands on when the arrival shows a DIFFERENT post from the
/// one that departed — `RevealDismissCardView`'s grid twin.
///
/// What it guarantees is the same short list the card's tests pin, because the
/// two are one design read on two shapes: a free-standing cell on its own fill,
/// inert, sized to what it is landing on, with the flight driving the rounding
/// and the two opacity channels never both carrying content.
@MainActor
struct PostGridTileStandInTests {
    private func post(_ kind: GalleryPost.Kind = .photo, cover: Bool = true) -> GalleryPost {
        GalleryPost(
            id: PostID("post-1"),
            kind: kind,
            isRepost: false,
            thumbnailURL: cover ? URL(string: "mock://cover/post-1") : nil,
            aspectRatio: 1,
            caption: "",
            publishedAtMS: 0
        )
    }

    private func standIn(
        _ kind: GalleryPost.Kind = .photo,
        size: CGSize = CGSize(width: 130, height: 190),
        cornerRadius: CGFloat = PostGridTileCell.mosaicCornerRadius
    ) -> PostGridTileStandInView {
        PostGridTileStandInView(
            post: post(kind),
            size: size,
            cornerRadius: cornerRadius,
            imagePipeline: ImagePipeline(fetcher: PlaceholderImageFetcher())
        )
    }

    /// THE DIVISION THE WHOLE TYPE EXISTS FOR: two opacities, not one.
    ///
    /// The view is the tile's FILL and the tile is what it holds. A fade only
    /// works against NOTHING — `RevealTransition` paid for that four times over
    /// with a caption ghost — so the hand-off empties the window between the two
    /// pictures rather than blending them, and it can only do that if the fill
    /// and the tile move on separate channels.
    @Test func theFillAndItsTileFadeIndependently() {
        let view = standIn()
        view.alpha = 0.4
        view.setContentOpacity(0.1)

        // Compared with a tolerance, never `==`: these are `CGFloat`s round-
        // tripped through a float, and 0.4 comes back as 0.40000000596.
        #expect(abs(view.alpha - 0.4) < 0.001)
        #expect(abs((view.subviews.first?.alpha ?? 0) - 0.1) < 0.001)
    }

    /// The empty beat is the colour the brick would have shown anyway. A fill
    /// that were a third opinion about the floor would make the middle of the
    /// hand-off a shade the landing never has.
    @Test func theFillIsTheTilesOwnFloor() throws {
        for kind in [GalleryPost.Kind.photo, .video] {
            let view = standIn(kind)
            let tile = try #require(view.subviews.first as? PostGridTileCell)
            #expect(view.backgroundColor == tile.contentView.backgroundColor)
        }
        // …and the two floors genuinely differ, so the check above is not
        // comparing one constant with itself: a video tile keeps a dark stage
        // because its poster may be unrenderable.
        #expect(standIn(.photo).backgroundColor != standIn(.video).backgroundColor)
    }

    /// ⚠️ THE TILE FILLS THE WINDOW AT EVERY SIZE. It used to be built at the
    /// landing cell's size and centred — the CARD's arrangement, whose reason
    /// is that stretching a card re-wraps its caption and the extra width
    /// around it is fill on fill, invisible. Neither half transfers to a brick.
    /// A tile has no caption, and its extra is the opposite of invisible: the
    /// window starts full-screen, so the flight showed a large grey rectangle
    /// with a postage stamp of the photograph in the middle of it, for most of
    /// its length. Filmed before this changed.
    ///
    /// Re-cropping every frame is what the fix BUYS, not what it costs: the
    /// cover is aspect-fill, and recomputing it against the travelling bounds
    /// is what keeps the morph continuous at any aspect —
    /// `zoomLiveMediaTracksCardBounds` records the same reasoning for the
    /// flight card.
    @Test func theTileFillsTheWindowAtEverySize() {
        let view = standIn(size: CGSize(width: 130, height: 190))
        for size in [
            CGSize(width: 393, height: 700),
            CGSize(width: 260, height: 400),
            CGSize(width: 130, height: 190)
        ] {
            view.frame = CGRect(origin: .zero, size: size)
            view.layoutIfNeeded()
            let tile = view.subviews.first
            #expect(tile?.bounds.size == size,
                    "a brick smaller than its window leaves the fill showing around it")
        }
    }

    /// And the tile rounds WITH the window. It clips its own cover, so a tile
    /// left at the landing radius would square off the picture inside a window
    /// that has already rounded.
    @Test func theTileRoundsWithTheWindow() throws {
        let view = standIn(size: CGSize(width: 130, height: 190))
        let tile = try #require(view.subviews.first as? PostGridTileCell)
        view.setCornerRadius(28)
        #expect(view.layer.cornerRadius == 28)
        #expect(tile.cornerRadius == 28)
    }

    /// The window's rounding is the flight's to drive, so the stand-in is the
    /// window's shape at every size rather than a rectangle inside it.
    @Test func theFlightDrivesTheWindowsRounding() {
        let view = standIn()
        view.setCornerRadius(26)
        #expect(view.layer.cornerRadius == 26)
    }

    /// The PAGE's rounding for the brick itself, which is a separate number:
    /// the two grids sharing this cell space their tiles differently, and gap
    /// and curve are one decision. A stand-in wearing the default would land a
    /// differently-curved tile on the mosaic that widened its gutter.
    @Test func thePageDecidesTheTilesOwnRounding() throws {
        let view = standIn(cornerRadius: 18)
        let tile = try #require(view.subviews.first as? PostGridTileCell)
        #expect(tile.contentView.layer.cornerRadius == 18)

        let defaulted = standIn()
        let defaultedTile = try #require(defaulted.subviews.first as? PostGridTileCell)
        #expect(defaultedTile.contentView.layer.cornerRadius == PostGridTileCell.mosaicCornerRadius)
    }

    /// It takes no touches — it is scenery flying over a live screen.
    @Test func itIsInert() {
        #expect(standIn().isUserInteractionEnabled == false)
    }

    /// It holds a REAL cell, which is the whole reason it is not an image view:
    /// a post that never departed has no cover to be handed, so the arrival has
    /// to ask the pipeline itself — and a cell already knows how.
    @Test func itHoldsARealTileWiredToThePipeline() throws {
        let view = standIn()
        let tile = try #require(view.subviews.first as? PostGridTileCell)
        // Nothing decoded yet, and that is the state the readiness gate waits
        // out — the point is that there is a cell here to receive it.
        #expect(tile.renderedCover == nil)
    }
}
