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
