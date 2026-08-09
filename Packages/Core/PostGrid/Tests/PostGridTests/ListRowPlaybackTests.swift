import CoreModels
import Foundation
import MediaCore
import MediaPlayback
import Testing
import UIKit
@testable import PostGrid

/// A TIMELINE ROW CAN PLAY, AND IT IS NOT A TILE.
///
/// Autoplay used to be the mosaic's alone — the coordinator named
/// `PostGridTileCell` outright, and list pages were given no coordinator at
/// all. Rows now play too, one at a time, which meant extracting
/// `GridPlaybackCell` and giving the row a surface of its own.
///
/// The row is not a smaller tile, and these cover the places that differ. A
/// tile IS its media, so its surface fills the cell; a row is a card of which
/// the media is one part, so the surface belongs inside the preview box — which
/// is what makes it inherit the box's rounding and the alpha a flight applies,
/// instead of needing either handled twice.
@MainActor
struct ListRowPlaybackTests {
    /// `shape` is derived from the aspect ratio, so the ratio is what a test
    /// sets: 16:9 lands in `.landscape`, 1:1 in `.square`.
    private func post(_ kind: GalleryPost.Kind, aspectRatio: Double = 16.0 / 9) -> GalleryPost {
        GalleryPost(
            id: PostID("p"), kind: kind, isRepost: false, thumbnailURL: nil,
            videoURL: kind == .video ? URL(string: "mock://video/0")! : nil,
            aspectRatio: aspectRatio,
            caption: "caption", publishedAtMS: 0
        )
    }

    private func row(_ kind: GalleryPost.Kind = .video) -> PostGridListRowCell {
        let cell = PostGridListRowCell(frame: CGRect(x: 0, y: 0, width: 390, height: 320))
        cell.configure(with: post(kind), imagePipeline: ImagePipeline(fetcher: PlaceholderImageFetcher()))
        cell.layoutIfNeeded()
        return cell
    }

    /// The coordinator can address a row at all — the point of the protocol.
    @Test func aRowIsAPlaybackCell() {
        #expect(row() is any GridPlaybackCell)
    }

    /// Asking whether a cell COULD be playing must not allocate the layer, or
    /// every still row in a timeline pays for a player it never uses.
    @Test func askingForTheSurfaceDoesNotBuildIt() {
        let cell = row()

        #expect(cell.loadedVideoRenderView == nil)

        let made = cell.makeVideoRenderViewIfNeeded()
        #expect(cell.loadedVideoRenderView === made)
        #expect(cell.makeVideoRenderViewIfNeeded() === made, "a second ask must reuse the first surface")
    }

    /// The regression the first playing row showed on screen: `pin(to:)` begins
    /// with `addSubview`, which moves the view to the FRONT — so ordering the
    /// surface before pinning it was silently undone and the ▶ badge, the thing
    /// that marks a row as video, disappeared the moment it started playing.
    @Test func theSurfaceSitsUnderneathThePlayBadge() {
        let cell = row()
        let surface = cell.makeVideoRenderViewIfNeeded()

        guard let box = surface.superview else {
            Issue.record("the surface was never parented")
            return
        }
        guard let badge = box.subviews.compactMap({ $0 as? UIImageView }).last,
              badge !== surface else {
            Issue.record("no badge alongside the surface")
            return
        }
        let surfaceIndex = box.subviews.firstIndex(of: surface)
        let badgeIndex = box.subviews.firstIndex(of: badge)
        #expect(surfaceIndex! < badgeIndex!, "the badge must keep reading over moving video")
    }

    /// The surface goes INSIDE the preview box, which is what makes a flight's
    /// concealment cover it for free. A sibling would stay visible over the
    /// flight and would have to be hidden separately.
    @Test func concealingThePreviewConcealsTheVideoWithIt() {
        let cell = row()
        let surface = cell.makeVideoRenderViewIfNeeded()

        cell.setHeroMediaConcealed(true)

        var view: UIView? = surface
        var concealed = false
        while let current = view, current !== cell {
            if current.alpha == 0 { concealed = true }
            view = current.superview
        }
        #expect(concealed, "the video stayed visible while its twin was in the air")
    }

    /// A recycled row must hand the player back BEFORE it is bound to another
    /// post, or it renders the previous post's video under the new cover.
    @Test func aRecycledRowReturnsItsPlayerAndItsConcealment() {
        let cell = row()
        var returned = false
        cell.onReuse = { returned = true }
        cell.setHeroMediaConcealed(true)

        cell.prepareForReuse()

        #expect(returned, "the coordinator was never told to take its player back")
        #expect(cell.mediaHeroRect != nil, "the preview stayed concealed into the next post")
        #expect(cell.onReuse == nil, "a stale callback would fire for the next post's player")
    }

    /// The shape rule differs by surface, and only here. Square video is
    /// excluded from the MOSAIC — filler bricks in a dense wall — but a row's
    /// preview is one fixed landscape box that aspect-fills anything, so
    /// applying the grid's rule there would leave those rows permanently still
    /// for a reason that never applied to them.
    @Test func squareVideoPlaysInARowButNotInTheMosaic() {
        let square = post(.video, aspectRatio: 1)

        #expect(square.hasPlayableVideo)
        #expect(square.autoplaysInGrid == false)
    }

    /// …and neither rule admits something with no stream behind it.
    @Test func aPhotoNeverPlaysOnEitherSurface() {
        let photo = post(.photo)

        #expect(photo.hasPlayableVideo == false)
        #expect(photo.autoplaysInGrid == false)
    }
}
