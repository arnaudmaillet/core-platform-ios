import AVFoundation
import Testing
import UIKit
@testable import MediaPlayback

/// The live video coming into focus over a low-resolution copy of itself
/// (#625). The ramp is arithmetic; the surface rule is that a pull needs a
/// decoded frame to draw from.
@MainActor
struct VideoFocusPullTests {
    @Test("The ramp starts at the sheet's resolution and rises, eased out, over the first 60%")
    func theRamp() {
        #expect(VideoFocusPull.resolution(at: 0, from: 0.35, to: 1.5) == 0.35)
        #expect(VideoFocusPull.resolution(at: 0.6, from: 0.35, to: 1.5) == 1.5)
        #expect(VideoFocusPull.resolution(at: 1, from: 0.35, to: 1.5) == 1.5)
        let early = VideoFocusPull.resolution(at: 0.15, from: 0.35, to: 1.5)
        #expect(early > 0.35 + (1.5 - 0.35) * 0.25, "eased out: ahead of linear early on")
    }

    @Test("The overlay is whole until 40%, then fades to nothing at the end")
    func theFade() {
        #expect(VideoFocusPull.overlayAlpha(at: 0) == 1)
        #expect(VideoFocusPull.overlayAlpha(at: 0.4) == 1)
        #expect(abs(VideoFocusPull.overlayAlpha(at: 0.7) - 0.5) < 1e-9)
        #expect(VideoFocusPull.overlayAlpha(at: 1) == 0)
    }

    @Test("The ramp stops short of the screen; a picture already near it is not pulled")
    func theEnd() {
        #expect(VideoFocusPull.endResolution(start: 0.35, screenScale: 3) == 1.5)
        #expect(VideoFocusPull.endResolution(start: 0.35, screenScale: 2) == 1)
        #expect(VideoFocusPull.endResolution(start: 1.9, screenScale: 3) == nil)
        #expect(VideoFocusPull.endResolution(start: 0, screenScale: 3) == nil)
    }

    @Test("The buffer scale gives the asked pixels per point under aspect-fill, never above the buffer's own")
    func theBufferScale() {
        let buffer = CGSize(width: 720, height: 1280)
        let surface = CGSize(width: 402, height: 874)
        // Aspect-fill: 874/1280 points per buffer pixel.
        let scale = VideoFocusPull.bufferScale(bufferSize: buffer, bounds: surface, pixelsPerPoint: 0.35)
        #expect(abs(scale - 0.35 * 874 / 1280) < 1e-9)
        #expect(VideoFocusPull.bufferScale(bufferSize: buffer, bounds: surface, pixelsPerPoint: 3) == 1)
    }

    @Test("A surface with no decoded frame has nothing to pull from, and is left alone")
    func noFrameNoPull() {
        let surface = VideoRenderView()
        surface.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        let before = surface.subviews.count
        #expect(surface.pullFocus(fromPixelsPerPoint: 0.35, over: 0.3) == false)
        #expect(surface.isPullingFocus == false)
        #expect(surface.subviews.count == before, "no overlay was added")
    }

    @Test("A prepared start is a resume the next fresh player spends, once")
    func aPreparedStartIsSpentOnce() {
        let pool = VideoPlaybackController(source: StubSource(), poolSize: 2, capacity: 2)
        let clip = URL(string: "mock://video/clip-46")!
        pool.prepareStart(of: clip, scope: "post-new-01", at: 1.83)
        #expect(pool.takeResume(scope: "post-new-01", url: clip)?.seconds == 1.83)
        #expect(pool.takeResume(scope: "post-new-01", url: clip) == nil)
    }

    private struct StubSource: VideoSource {
        func playableURL(for url: URL) async throws -> URL {
            FileManager.default.temporaryDirectory.appendingPathComponent("stub.mp4")
        }
    }
}
