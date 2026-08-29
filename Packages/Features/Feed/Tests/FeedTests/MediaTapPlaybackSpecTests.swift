import CoreModels
import MediaCore
import MediaPlayback
import PostGrid
import Testing
import UIKit
@testable import Feed

/// **THE SPECIFICATION FOR A FINGER ON A CLIP.**
///
/// Three facts a viewer could check by looking, on a post screen showing video:
///
/// * a tap on the picture stops it, and a glyph in the middle says so;
/// * a second tap starts it again, and the glyph goes;
/// * a press and hold stops it silently for exactly as long as it is held —
///   nothing was chosen, so nothing is announced.
///
/// And a fourth that decides where those apply: **the picture is the band
/// between the header and the page's bottom readout** — the comment band, or
/// the page dots when a gallery puts them above it. Everything below that line
/// is the page talking about the post (caption, ticker, toolbar), and a tap
/// there is not a tap on the clip.
///
/// ⚠️ WHY THIS IS A SPECIFICATION AND NOT A PATCH. The gestures were here
/// already and did nothing on the screen that matters most. A post opened from
/// a card lands by JOINING the clip its grid tile is already playing, and a
/// joined surface holds no pool loan — so every control, asked of the loan
/// table, answered "nothing is playing here" and returned false while the
/// viewer watched the picture move. The cell was not at fault and neither was
/// the pool's bookkeeping: the fix is that a surface answers for what it
/// DRAWS (`JoinedSurfaceControlTests`), and these cases are that fix seen from
/// the screen.
///
/// ⚠️ WHAT THIS CANNOT SEE. A unit test has no decoder. It can prove the
/// player was told to stop and that the glyph followed; it cannot prove frames
/// stopped arriving. That half is the simulator's, against `-media-log`'s
/// `[page-play] tap`/`hold` lines.
@MainActor
struct MediaTapPlaybackSpecTests {
    // MARK: - Fixtures

    private struct StubSource: VideoSource {
        func playableURL(for url: URL) async throws -> URL {
            FileManager.default.temporaryDirectory.appendingPathComponent("stub.mp4")
        }
    }

    private static let clip = URL(string: "mock://video/trailer")!

    private static func model(pages: Int = 0, videoPages: Bool = false) -> FeedItemDisplayModel {
        FeedItemDisplayModel(
            id: PostID("post-video"),
            authorID: ProfileID("profile-1"),
            authorName: "Ava",
            metaText: "@ava · 3m",
            avatarURL: nil,
            caption: "A caption long enough to take the two lines the page reserves for it.",
            mediaURL: clip,
            mediaKind: .video,
            thumbnailURL: nil,
            audioText: nil,
            likeCount: 0,
            timestampText: "now",
            extraMedia: (0..<pages).map {
                GalleryPost.MediaPage(
                    thumbnailURL: URL(string: "mock://media/\($0 + 1)"),
                    videoURL: videoPages ? URL(string: "mock://video/page-\($0 + 1)") : nil
                )
            }
        )
    }

    /// A post screen as a hero landing leaves it: the grid tile owns the
    /// player, and this page draws the same playback without owning anything.
    ///
    /// ⚠️ Built this way on purpose. Giving the page its own `play` would be a
    /// screen no viewer ever reaches — every post screen in the app is opened
    /// from a card — and it is exactly the arrangement the defect needed.
    private static func landedPage(pages: Int = 0)
        async -> (cell: SnapFeedCell, pool: VideoPlaybackController, tile: VideoRenderView) {
        let pool = VideoPlaybackController(source: StubSource(), poolSize: 4, capacity: 4)
        let cell = SnapFeedCell(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        cell.configure(
            with: model(pages: pages),
            pipeline: ImagePipeline(fetcher: PlaceholderImageFetcher()),
            videoPlayback: pool
        )
        // The screen's own thresholds: the nav zone the header floats in.
        cell.applyChromeInsets(UIEdgeInsets(top: 103, left: 0, bottom: 34, right: 0))
        cell.layoutIfNeeded()

        let tile = VideoRenderView()
        tile.frame = CGRect(x: 0, y: 0, width: 100, height: 100)
        await pool.play(clip, in: tile, scope: "post-video")
        _ = pool.attachSurface(cell.debugRenderSurface, to: clip)
        return (cell, pool, tile)
    }

    /// The middle of the media band, which is where a viewer's thumb lands.
    private static func mediaPoint(_ cell: SnapFeedCell) -> CGPoint {
        CGPoint(x: cell.bounds.midX, y: cell.bounds.midY)
    }

    // MARK: - The three facts

    @Test func aTapOnThePictureStopsTheClipAndSaysSo() async {
        let (cell, pool, tile) = await Self.landedPage()
        #expect(pool.isAdvancing(in: tile))

        cell.tapMedia(at: Self.mediaPoint(cell))

        #expect(pool.isAdvancing(in: tile) == false)
        #expect(cell.debugIsShowingPauseGlyph)
    }

    @Test func aSecondTapStartsItAgainAndTakesTheGlyphAway() async {
        let (cell, pool, tile) = await Self.landedPage()
        cell.tapMedia(at: Self.mediaPoint(cell))

        cell.tapMedia(at: Self.mediaPoint(cell))

        #expect(pool.isAdvancing(in: tile))
        #expect(cell.debugIsShowingPauseGlyph == false)
    }

    /// The hold: stopped while the finger is down, running again when it
    /// lifts, and SILENT throughout — the glyph is how a choice is announced,
    /// and holding chooses nothing.
    @Test func holdingStopsTheClipSilentlyAndLettingGoResumesIt() async {
        let (cell, pool, tile) = await Self.landedPage()

        cell.beginMediaHold(at: Self.mediaPoint(cell))
        #expect(pool.isAdvancing(in: tile) == false)
        #expect(cell.debugIsShowingPauseGlyph == false)

        cell.endMediaHold()
        #expect(pool.isAdvancing(in: tile))
        #expect(cell.debugIsShowingPauseGlyph == false)
    }

    /// ⚠️ AND A HOLD CANNOT START A CLIP THE VIEWER STOPPED. The release undoes
    /// the hold and nothing else — otherwise a paused post starts playing
    /// because a finger rested on it.
    @Test func aHoldOnAClipTheViewerPausedLeavesItPaused() async {
        let (cell, pool, tile) = await Self.landedPage()
        cell.tapMedia(at: Self.mediaPoint(cell)) // paused, glyph up

        cell.beginMediaHold(at: Self.mediaPoint(cell))
        cell.endMediaHold()

        #expect(pool.isAdvancing(in: tile) == false)
        #expect(cell.debugIsShowingPauseGlyph)
    }

    /// ⚠️ AND THE GLYPH GOES WHEN THE PAGE STARTS THE CLIP ITSELF.
    ///
    /// Paging away from a post and back is the page's own door — it resumes
    /// what it was showing — and a mark that says "you stopped this" left over
    /// a moving picture inverts the next tap: it would pause a clip that
    /// already looks paused.
    @Test func comingBackToAPausedPageTakesTheGlyphWithTheStop() async {
        let (cell, _, _) = await Self.landedPage()
        cell.tapMedia(at: Self.mediaPoint(cell))
        #expect(cell.debugIsShowingPauseGlyph)

        cell.setOwnsViewport(false) // paged away
        cell.setOwnsViewport(true)  // and back: the page starts it again

        #expect(cell.debugIsShowingPauseGlyph == false)
    }

    // MARK: - The mark rides the picture

    /// A gallery resting on a page that is playing — the state a viewer is in
    /// when they stop one page of several.
    ///
    /// ⚠️ NOT `willBecomeActive`, and the reason is a flake this suite already
    /// produced. Activation starts the clip in a Task of its own, so a fixture
    /// that waits for "a player is advancing" and then taps is racing work that
    /// is still running: the same two cases disagreed about whether the mark
    /// was up at all, from one run to the next. Here the page is handed a
    /// surface and a clip that is already running — which is exactly what a
    /// hero landing leaves behind — and nothing is in flight to interfere.
    private static func landedGallery(pages: Int)
        async -> (cell: SnapFeedCell, pool: VideoPlaybackController) {
        let pool = VideoPlaybackController(source: StubSource(), poolSize: 6, capacity: 6)
        let cell = SnapFeedCell(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        cell.configure(
            with: model(pages: pages - 1, videoPages: true),
            pipeline: ImagePipeline(fetcher: PlaceholderImageFetcher()),
            videoPlayback: pool
        )
        cell.applyChromeInsets(UIEdgeInsets(top: 103, left: 0, bottom: 34, right: 0))
        cell.layoutIfNeeded()
        cell.debugHostRenderViewOnCurrentPage()

        let tile = VideoRenderView()
        tile.frame = CGRect(x: 0, y: 0, width: 100, height: 100)
        await pool.play(clip, in: tile, scope: "post-video")   // page one's clip
        _ = pool.attachSurface(cell.debugRenderSurface, to: clip)
        #expect(pool.isAdvancing(in: cell.debugRenderSurface),
                Comment(rawValue: "the fixture never started playing"))
        return (cell, pool)
    }

    /// ⚠️ THE CLAIM, AS THE VIEWER SEES IT: the mark is ON the stopped page —
    /// and when that page leaves, it leaves with it.
    ///
    /// Centred on the SCREEN it belonged to nothing: it hung over the page
    /// arriving, which was playing, and said the opposite of the truth. The
    /// geometry of the ride itself — half out of the box, half of the mark
    /// still showing — is pinned one level down, in `CarouselPausedMarkTests`,
    /// where a drag can be expressed as an offset rather than a page.
    @Test func theMarkSitsOnTheStoppedPageAndLeavesWithIt() async throws {
        let (cell, _) = await Self.landedGallery(pages: 3)
        cell.tapMedia(at: Self.mediaPoint(cell))

        let onThePicture = try #require(cell.debugPausedMarkFrame(onPage: 0))
        #expect(abs(onThePicture.midX - cell.bounds.midX) < 1)

        cell.debugShowPage(1)
        cell.layoutIfNeeded()

        // Gone with its page, and the page arriving wears none of its own.
        #expect(cell.debugPausedMarkFrame(onPage: 0) == nil)
        #expect(cell.debugPausedMarkFrame(onPage: 1) == nil)
        #expect(cell.debugIsShowingPauseGlyph == false)

        // …and coming back finds nothing to clear: arriving starts the clip.
        cell.debugShowPage(0)
        #expect(cell.debugPausedMarkFrame(onPage: 0) == nil)
    }

    /// And a single-attachment post still wears its mark over its own picture —
    /// the card is the picture there, so the two coincide.
    @Test func aSinglePicturesMarkSitsOnThatPicture() async throws {
        let (cell, _, _) = await Self.landedPage()
        cell.tapMedia(at: Self.mediaPoint(cell))

        let mark = try #require(cell.debugPausedMarkFrame(onPage: 0))
        #expect(abs(mark.midX - cell.bounds.midX) < 1)
        #expect(abs(mark.midY - cell.bounds.midY) < 1)
    }

    // MARK: - Where the clip's territory ends

    @Test func theHeaderBandIsNotTheClipsTerritory() async {
        let (cell, pool, tile) = await Self.landedPage()
        let inTheHeader = CGPoint(x: cell.bounds.midX, y: 60) // beside the back arrow

        #expect(cell.playbackTapRegionContains(inTheHeader) == false)
        cell.tapMedia(at: inTheHeader)
        #expect(pool.isAdvancing(in: tile))
        #expect(cell.debugIsShowingPauseGlyph == false)
    }

    /// The bottom readout — comment band, caption, everything under it — is
    /// the page talking, not the picture.
    @Test func theBottomReadoutIsNotTheClipsTerritory() async {
        let (cell, pool, tile) = await Self.landedPage()
        let onTheCaption = CGPoint(x: cell.bounds.midX, y: cell.bounds.height - 90)

        #expect(cell.playbackTapRegionContains(onTheCaption) == false)
        cell.tapMedia(at: onTheCaption)
        #expect(pool.isAdvancing(in: tile))
    }

    /// A gallery hangs its page dots above the comment band, so the clip's
    /// floor rises to meet them: the strip that carries the dots belongs to
    /// the readout, and a tap that pauses a single-clip post has to stop
    /// pausing there.
    @Test func aGallerysPageDotsRaiseTheClipsFloor() async {
        let (single, _, _) = await Self.landedPage()
        let (gallery, _, _) = await Self.landedPage(pages: 4)

        let singleFloor = single.debugPlaybackTapRegion.maxY
        let galleryFloor = gallery.debugPlaybackTapRegion.maxY
        #expect(galleryFloor < singleFloor,
                Comment(rawValue: "dots did not lift the floor: \(galleryFloor) vs \(singleFloor)"))

        // The strip between the two floors: the clip's on a single-media post,
        // the readout's on a gallery.
        let betweenTheFloors = CGPoint(x: single.bounds.midX, y: (galleryFloor + singleFloor) / 2)
        #expect(single.playbackTapRegionContains(betweenTheFloors))
        #expect(gallery.playbackTapRegionContains(betweenTheFloors) == false)
    }

    /// Both ends of the region are the screen's own thresholds, not numbers of
    /// this file's own: the header's floor is the frozen inset the chrome is
    /// laid out against.
    @Test func theRegionStartsWhereTheHeaderEnds() async {
        let (cell, _, _) = await Self.landedPage()
        let region = cell.debugPlaybackTapRegion

        #expect(region.minY == 103)
        #expect(region.maxY > region.minY)
        #expect(cell.playbackTapRegionContains(CGPoint(x: 200, y: 104)))
        #expect(cell.playbackTapRegionContains(CGPoint(x: 200, y: 102)) == false)
    }

    // MARK: - The engaged screen keeps its own meaning

    /// ⚠️ WITH THE THREAD OPEN, THE STRIP IS THE WAY BACK — and it stays that
    /// way. The visible media band above the comments is the one piece of the
    /// page the panel does not cover, and its job there is to bring the media
    /// back; pausing would take the screen's only expand-back gesture and give
    /// nothing in return.
    @Test func theStripStillExpandsWhileTheThreadIsOpen() async {
        let (cell, pool, tile) = await Self.landedPage()
        var expanded = 0
        cell.onRequestCommentsClose = { expanded += 1 }
        cell.setCommentsEngaged(true)

        cell.tapMedia(at: Self.mediaPoint(cell))
        #expect(expanded == 1)
        #expect(pool.isAdvancing(in: tile))

        // …and the hold is off duty there too, so the two gestures cannot
        // disagree about whose territory this is.
        cell.beginMediaHold(at: Self.mediaPoint(cell))
        #expect(pool.isAdvancing(in: tile))
    }
}
