import AVFoundation
import Foundation
import Testing
@testable import MediaPlayback

/// **PLAYING A CLIP FASTER OR SLOWER THAN IT WAS SHOT.**
///
/// The editor's timeline gives each piece of a clip its own rate, and what the
/// export produces has to be what the author watched. This is the preview half
/// of that: `VideoExporter` carries the other, through
/// `composition.scaleTimeRange`.
///
/// ⚠️ **A REAL PLAYER OVER A REAL FILE, LIKE `ScrubWhilePausedTests`.** The
/// distinction being tested — that stating a rate does NOT start a stopped clip —
/// is entirely about what `AVPlayer` does with `rate` versus `defaultRate`, and a
/// stub would answer whatever it was written to answer.
@MainActor
struct PlaybackRateTests {
    private struct Passthrough: VideoSource {
        func playableURL(for url: URL) async throws -> URL { url }
    }

    private func clip(seconds: Double = 3) async throws -> URL {
        try await PlaceholderVideoFetcher(durationSeconds: seconds)
            .playableURL(for: URL(string: "mock://video/rate?w=240&h=240")!)
    }

    private func bound(_ file: URL) async throws -> (VideoPlaybackController, VideoRenderView) {
        let controller = VideoPlaybackController(source: Passthrough(), poolSize: 1, capacity: 1)
        let surface = VideoRenderView()
        surface.frame = CGRect(x: 0, y: 0, width: 80, height: 80)
        await controller.play(file, in: surface)
        for _ in 0..<400 {
            if controller.playhead(in: surface) != nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        return (controller, surface)
    }

    @Test func aRunningClipTakesTheRateAtOnce() async throws {
        let (controller, surface) = try await bound(try await clip())
        _ = try #require(controller.playhead(in: surface), "guard: the item reported a length")
        controller.setPaused(false, in: surface)

        #expect(controller.setRate(2, in: surface))

        let rates = try #require(controller.debugRates(in: surface))
        #expect(rates.rate == 2, "the clip is still running at \(rates.rate)")
        #expect(rates.next == 2, "and the next resume would drop back to \(rates.next)")
    }

    /// ⚠️ **THE ONE THAT MAKES `defaultRate` NECESSARY.** Assigning `rate`
    /// STARTS playback — a paused clip told to run at 2× would begin playing on
    /// the spot, undoing a pause the author asked for. "Set the speed" and "go"
    /// are different instructions.
    @Test func astoppedClipIsGivenTheRateWithoutBeingStarted() async throws {
        let (controller, surface) = try await bound(try await clip())
        _ = try #require(controller.playhead(in: surface), "guard: the item reported a length")
        controller.setPaused(true, in: surface)

        #expect(controller.setRate(2, in: surface))

        #expect(controller.isPaused(in: surface) == true, "setting a speed started the clip")
        let rates = try #require(controller.debugRates(in: surface))
        #expect(rates.rate == 0, "it is moving at \(rates.rate)")
        #expect(rates.next == 2, "and it would resume at \(rates.next) rather than the rate asked for")
    }

    /// And the rate the author chose is the one the clip comes back at.
    @Test func resumingUsesTheRateThatWasChosen() async throws {
        let (controller, surface) = try await bound(try await clip())
        _ = try #require(controller.playhead(in: surface), "guard: the item reported a length")
        controller.setPaused(true, in: surface)
        controller.setRate(2, in: surface)

        controller.setPaused(false, in: surface)

        let rates = try #require(controller.debugRates(in: surface))
        #expect(rates.rate == 2, "it resumed at \(rates.rate)")
    }

    @Test func aRateThatMeansNothingIsRefused() async throws {
        let (controller, surface) = try await bound(try await clip())
        _ = try #require(controller.playhead(in: surface), "guard: the item reported a length")
        controller.setPaused(false, in: surface)
        controller.setRate(2, in: surface)

        #expect(controller.setRate(0, in: surface) == false)
        #expect(controller.setRate(.nan, in: surface) == false)

        let rates = try #require(controller.debugRates(in: surface))
        #expect(rates.next == 2, "a nonsense rate overwrote a good one: \(rates.next)")
    }

    @Test func asurfaceWithNoPlayerHasNoRateToSet() {
        let controller = VideoPlaybackController(source: Passthrough(), poolSize: 1, capacity: 1)
        #expect(controller.setRate(2, in: VideoRenderView()) == false)
    }
}
