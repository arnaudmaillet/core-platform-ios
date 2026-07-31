import AVFoundation
import Testing
import UIKit
@testable import MediaPlayback

/// Phase 1 of #83. These run under BOTH backings — `swift test` exercises the
/// `AVPlayerLayer` path, and the same suite with `AVSBDL_RENDER=1` exercises
/// `AVSampleBufferDisplayLayer`. `layerClass` is resolved once per process, so
/// a single run can only ever see one of them; anything asserted here has to
/// hold either way, and `backingMatchesTheFlag` is what proves the run actually
/// got the backing it thinks it did.
@MainActor
struct VideoFrameRendererTests {
    private var stubURL: URL { FileManager.default.temporaryDirectory.appendingPathComponent("renderer-stub.mp4") }

    @Test func backingMatchesTheFlag() {
        let expected: AnyClass = VideoRenderFlags.usesSampleBufferLayer
            ? AVSampleBufferDisplayLayer.self
            : AVPlayerLayer.self
        // Printed, not merely asserted. A green suite says nothing about WHICH
        // backing it covered, and a CI job that silently ran the old path twice
        // would look identical to one that ran both — the same "silence read as
        // success" trap this issue has already been caught by twice.
        print("[avsbdl-test] backing = \(expected)")
        #expect(ObjectIdentifier(VideoRenderView.layerClass) == ObjectIdentifier(expected))
        // The point of the whole flag: a consumer holds the same type and sees
        // the same surface either way.
        #expect(VideoRenderView().isReadyForDisplay == false)
    }

    @Test func surfacesAreASetAndAddingTwiceIsIdempotent() {
        let renderer = VideoFrameRenderer(player: AVPlayer())
        let first = VideoRenderView()
        let second = VideoRenderView()

        renderer.addSurface(first)
        renderer.addSurface(first)
        #expect(renderer.surfaceCount == 1)

        // Plural from the start: Phase 2's N-surface handoff is this line, not
        // a rewrite.
        renderer.addSurface(second)
        #expect(renderer.surfaceCount == 2)

        renderer.removeSurface(first)
        #expect(renderer.surfaceCount == 1)
    }

    @Test func invalidatingReleasesEverySurface() {
        let renderer = VideoFrameRenderer(player: AVPlayer())
        let view = VideoRenderView()
        renderer.addSurface(view)

        renderer.invalidate()
        #expect(renderer.surfaceCount == 0)
        #expect(view.isReadyForDisplay == false)
    }

    /// The display link must exist only while some renderer both has something
    /// to pull and somewhere to put it. A pooled player parked between items is
    /// the common case in this app — six of them keeping a 120Hz link alive for
    /// nothing is exactly the cost this design is supposed to avoid.
    @Test func clockRunsOnlyWhileAFrameCouldActuallyBeDispatched() {
        let renderer = VideoFrameRenderer(player: AVPlayer())
        let view = VideoRenderView()

        // A surface with no item: nothing to pull.
        renderer.addSurface(view)
        #expect(renderer.debugIsRegisteredWithClock == false)

        // An item with no surface: nowhere to put it.
        renderer.removeSurface(view)
        renderer.setItem(AVPlayerItem(url: stubURL))
        #expect(renderer.debugIsRegisteredWithClock == false)

        // Both → registered.
        renderer.addSurface(view)
        #expect(renderer.debugIsRegisteredWithClock == true)

        renderer.invalidate()
        #expect(renderer.debugIsRegisteredWithClock == false)
    }

    /// Losing the item has to unregister even while surfaces stay attached —
    /// this is the `detach` path, where the player goes back to the idle pool
    /// but the view it was rendering into is still on screen.
    @Test func clearingTheItemUnregistersEvenWithSurfacesStillAttached() {
        let renderer = VideoFrameRenderer(player: AVPlayer())
        let view = VideoRenderView()
        renderer.setItem(AVPlayerItem(url: stubURL))
        renderer.addSurface(view)
        #expect(renderer.debugIsRegisteredWithClock == true)

        renderer.setItem(nil)
        #expect(renderer.debugIsRegisteredWithClock == false)
        #expect(renderer.surfaceCount == 1)
    }

    /// Frame counting replaces `isReadyForDisplay` as the liveness signal (see
    /// the note on `VideoRenderView.enqueuedFrameCount`). A surface that has
    /// never been fed must say so, in either backing.
    @Test func aSurfaceThatHasReceivedNoFramesReportsNoFrames() {
        let view = VideoRenderView()
        #expect(view.enqueuedFrameCount == 0)
        #expect(view.lastFrameHostTime == 0)
    }
}

/// A source that hands back a fixed URL without touching the disk, so surface
/// bookkeeping is tested independently of real synthesis or playback.
private struct FixedVideoSource: VideoSource {
    let url: URL
    func playableURL(for url: URL) async throws -> URL { self.url }
}

/// Phase 2 of #83: one decoder, several surfaces.
///
/// The assertions are backing-dependent **on purpose**. Under
/// `AVSampleBufferDisplayLayer` a second surface genuinely joins and both draw;
/// under `AVPlayerLayer` only one layer can render whatever is attached, and
/// these tests say so rather than flattering it. That difference IS the
/// feature, so a test that hid it would be measuring nothing.
@MainActor
struct SurfaceAttachmentTests {
    private var stubURL: URL { FileManager.default.temporaryDirectory.appendingPathComponent("surface-stub.mp4") }
    /// Surfaces that can concurrently render one player: N when we dispatch
    /// frames ourselves, 1 when `AVPlayerLayer` owns the render slot.
    private var concurrentSurfaces: Int { VideoRenderFlags.usesSampleBufferLayer ? 2 : 1 }

    @Test func aSecondSurfaceJoinsWhatIsAlreadyPlaying() async {
        let controller = VideoPlaybackController(source: FixedVideoSource(url: stubURL), poolSize: 3)
        let url = URL(string: "mock://video/surfaces")!
        let primary = VideoRenderView()
        await controller.play(url, in: primary)
        #expect(controller.surfaceCount(for: url) == 1)

        let flight = VideoRenderView()
        #expect(controller.attachSurface(flight, to: url) == true)
        #expect(controller.surfaceCount(for: url) == concurrentSurfaces)
        // The point of the whole pivot: attaching a second surface does not
        // take anything away from the first.
        #expect(primary.isAttached)
        #expect(flight.isAttached)
    }

    @Test func attachingToSomethingNotPlayingIsRefused() {
        let controller = VideoPlaybackController(source: FixedVideoSource(url: stubURL), poolSize: 3)
        let url = URL(string: "mock://video/idle")!
        #expect(controller.attachSurface(VideoRenderView(), to: url) == false)
        #expect(controller.surfaceCount(for: url) == nil)
    }

    /// A dismissal attaches its landing surface after the page that owned the
    /// player has already let go, so the only thing still holding the asset is
    /// the park. Without this the landing has nothing to join and falls back to
    /// opening a second item at zero — the restart the hero flight exists to
    /// avoid.
    @Test func aParkedPlayerIsStillJoinable() async {
        let controller = VideoPlaybackController(source: FixedVideoSource(url: stubURL), poolSize: 3)
        let url = URL(string: "mock://video/parked")!
        let page = VideoRenderView()
        await controller.play(url, in: page)
        #expect(controller.parkPlayback(from: page) == true)

        let landing = VideoRenderView()
        #expect(controller.attachSurface(landing, to: url) == true)
        #expect(landing.isAttached)
    }

    @Test func detachingASurfaceLeavesThePlaybackAndItsOwnerAlone() async {
        let controller = VideoPlaybackController(source: FixedVideoSource(url: stubURL), poolSize: 3)
        let url = URL(string: "mock://video/detach")!
        let primary = VideoRenderView()
        await controller.play(url, in: primary)
        let flight = VideoRenderView()
        controller.attachSurface(flight, to: url)

        controller.detachSurface(flight)
        #expect(flight.isAttached == false)
        #expect(primary.isAttached)
        #expect(controller.surfaceCount(for: url) == 1)
    }

    /// The dismissal's core move: the landing tile takes the loan while the
    /// page that owned it is still alive and still drawing.
    @Test func ownershipMovesWithoutDisturbingAnySurface() async {
        let controller = VideoPlaybackController(source: FixedVideoSource(url: stubURL), poolSize: 3)
        let url = URL(string: "mock://video/transfer")!
        let page = VideoRenderView()
        await controller.play(url, in: page)
        let tile = VideoRenderView()
        controller.attachSurface(tile, to: url)

        #expect(controller.transferOwnership(of: url, to: tile) == true)
        // Both are still showing it — ownership moved, rendering did not.
        #expect(tile.isAttached)
        #expect(page.isAttached)
        #expect(controller.surfaceCount(for: url) == concurrentSurfaces)
    }

    /// Why `transferOwnership` has to happen BEFORE the feed is torn down.
    ///
    /// Without it, stopping the owning page returns the player to the pool and
    /// every joined surface goes dark — including the grid tile the flight just
    /// landed on. With it, the page can be stopped and the tile keeps playing.
    @Test func stoppingTheFormerOwnerLeavesTheNewOnePlaying() async {
        let controller = VideoPlaybackController(source: FixedVideoSource(url: stubURL), poolSize: 3)
        let url = URL(string: "mock://video/teardown")!
        let page = VideoRenderView()
        await controller.play(url, in: page)
        let tile = VideoRenderView()
        controller.transferOwnership(of: url, to: tile)

        controller.stop(page)
        #expect(tile.isAttached)
        #expect(controller.surfaceCount(for: url) != nil)
    }

    /// `detachSurface` must never return a pool loan — the owning view's player
    /// is not its to release. Passing the owner is a caller mistake, and the
    /// safe response is to do nothing rather than tear down playback.
    @Test func detachingTheOwningViewIsRefusedRatherThanTearingItDown() async {
        let controller = VideoPlaybackController(source: FixedVideoSource(url: stubURL), poolSize: 3)
        let url = URL(string: "mock://video/owner")!
        let primary = VideoRenderView()
        await controller.play(url, in: primary)

        controller.detachSurface(primary)
        #expect(primary.isAttached)
        #expect(controller.surfaceCount(for: url) == 1)
    }
}
