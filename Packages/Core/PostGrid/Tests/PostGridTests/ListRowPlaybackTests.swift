import CoreModels
import Foundation
import MediaCore
import MediaPlayback
import Testing
import UIKit
@testable import PostGrid

/// Hands back a fixed URL without touching the disk, so the coordinator's
/// bookkeeping is tested independently of real playback.
private struct FixedRowVideoSource: VideoSource {
    let url: URL
    func playableURL(for url: URL) async throws -> URL { self.url }
}

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

    private func makePool() -> VideoPlaybackController {
        VideoPlaybackController(
            source: FixedRowVideoSource(url: FileManager.default.temporaryDirectory
                .appendingPathComponent("stub.mp4")),
            poolSize: 6
        )
    }

    private func rowCandidate(_ index: Int, distance: CGFloat) -> GridVideoPlaybackCoordinator.Candidate {
        .init(
            id: PostID("row-\(index)"),
            url: URL(string: "mock://video/\(index)")!,
            cell: row(),
            distanceFromCentre: distance
        )
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

    /// ⚠️ NOTHING SITS OVER THE PICTURE.
    ///
    /// A row used to carry a ▶ glyph the surface had to be ordered beneath, and
    /// getting that order wrong was a real regression once ("the badge vanishes
    /// the moment it plays"). The mark is gone — a clip on a card starts by
    /// itself, so the picture moving is the signal — and with it the whole
    /// class of ordering bugs. Asserted as "the surface is topmost", which is
    /// the property that was actually wanted all along.
    @Test func nothingIsDrawnOverThePlayingSurface() {
        let cell = row()
        let surface = cell.makeVideoRenderViewIfNeeded()

        guard let box = surface.superview else {
            Issue.record("the surface was never parented")
            return
        }

        #expect(box.subviews.last === surface)
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

    /// The timeline's cap and its handover, exercised through ROW cells.
    ///
    /// The cap itself is covered generically in the coordinator's own suite,
    /// but always with tiles. What is untested until here is that the same
    /// bookkeeping survives the protocol: `playing` is keyed by post and its
    /// values are compared by identity, so a row that a scroll pushed out has
    /// to be found and stopped exactly as a tile would be.
    ///
    /// Five candidates more than the cap allows, so eviction is forced rather
    /// than incidental — the sim cannot produce this, because the fixtures
    /// never put more than two video rows on screen at once.
    @Test func theTimelineKeepsTheNearestFiveAndDropsTheRest() {
        let coordinator = GridVideoPlaybackCoordinator(pool: makePool(), maxConcurrent: 5)
        // Deliberately handed to the coordinator far-first: the ranking must
        // come from the distances, not from the caller's enumeration order.
        let candidates = (0..<8).map { rowCandidate($0, distance: CGFloat(800 - $0 * 100)) }

        coordinator.update(candidates: candidates)

        #expect(coordinator.playingIDs.count == 5)
        #expect(coordinator.playingIDs == Set((3..<8).map { PostID("row-\($0)") }),
                "the five nearest the centre are rows 3…7, whatever order they arrived in")
    }

    /// …and the handover a scroll performs: the centre moves, so a row that
    /// was playing must give its player to one that was not.
    @Test func aScrolledAwayRowGivesUpItsPlayer() {
        let coordinator = GridVideoPlaybackCoordinator(pool: makePool(), maxConcurrent: 1)
        let leaving = rowCandidate(0, distance: 10)
        let arriving = rowCandidate(1, distance: 900)
        coordinator.update(candidates: [leaving, arriving])
        #expect(coordinator.playingIDs == [PostID("row-0")])

        // The viewer scrolls: the far row is now the central one.
        coordinator.update(candidates: [
            rowCandidate(0, distance: 900),
            .init(id: arriving.id, url: arriving.url, cell: arriving.cell, distanceFromCentre: 10)
        ])

        #expect(coordinator.playingIDs == [PostID("row-1")],
                "the row that left kept its player, so the arriving one never got a slot")
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
