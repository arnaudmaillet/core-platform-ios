import AVFoundation
import Foundation
import Testing
@testable import MediaPlayback

/// **A PLAYED RANGE LOOPS ON THE EDITOR'S ITEM** — the few seconds around a cut
/// while its transition is being chosen — and leaks into nothing else.
///
/// A real player over a real file: whether the playhead stays inside the range
/// is AVFoundation's answer, and a stub would answer whatever it was written to.
@MainActor
@Suite(.serialized)
struct RehearsalLoopTests {
    private struct Passthrough: VideoSource {
        func playableURL(for url: URL) async throws -> URL { url }
    }

    private func surface() -> VideoRenderView {
        let view = VideoRenderView()
        view.frame = CGRect(x: 0, y: 0, width: 80, height: 80)
        return view
    }

    private func controller(pool: Int = 1) -> VideoPlaybackController {
        VideoPlaybackController(source: Passthrough(), poolSize: pool, capacity: 1)
    }

    /// Every playhead sample for `seconds`, 10ms apart.
    private func samples(
        _ controller: VideoPlaybackController, _ view: VideoRenderView, for seconds: Double
    ) async throws -> [Double] {
        var taken: [Double] = []
        for _ in 0..<Int(seconds * 100) {
            try await Task.sleep(for: .milliseconds(10))
            if let now = controller.playheadSeconds(in: view) { taken.append(now) }
        }
        return taken
    }

    /// The first sample after each backward jump.
    private func wraps(_ taken: [Double]) -> [Double] {
        zip(taken, taken.dropFirst()).compactMap { before, after in after + 0.3 < before ? after : nil }
    }

    private func loadWholeClip(
        _ controller: VideoPlaybackController, _ view: VideoRenderView,
        loop: ClosedRange<Double>?, segments: [VideoExportSegment] = [], picture: Bool = true,
        at seconds: Double? = nil
    ) async throws {
        let file = try await ColourClipWriter.clip(picture: picture)
        await controller.load(VideoExportPlan(sourceURL: file, segments: segments), in: view) {
            VideoLoadLanding(seconds: seconds ?? loop?.lowerBound ?? 0, loop: loop)
        }
        #expect(controller.hasPlayer(in: view), "guard: nothing was loaded")
    }

    @Test func aRehearsalStaysInsideItsRange() async throws {
        let controller = controller()
        let view = surface()
        defer { controller.stop(view) }
        try await loadWholeClip(controller, view, loop: 1.0...2.0)

        let taken = try await samples(controller, view, for: 3.5)

        #expect(wraps(taken).count >= 2, "guard: it did not loop twice: \(wraps(taken))")
        let low = try #require(taken.dropFirst(5).min())
        let high = try #require(taken.max())
        #expect(low >= 0.99, "the rehearsal played before its range: \(low)")
        #expect(high <= 2.0 + 1.0 / 30 + 0.01, "the rehearsal played past its range: \(high)")
    }

    @Test func aWrapLandsOnTheRangeStart() async throws {
        let controller = controller()
        let view = surface()
        defer { controller.stop(view) }
        try await loadWholeClip(controller, view, loop: 1.0...2.0)

        let landings = wraps(try await samples(controller, view, for: 3.5))

        #expect(!landings.isEmpty, "guard: it never looped")
        for landing in landings {
            #expect(abs(landing - 1.0) < 0.1, "a wrap landed at \(landing), not at the range's start")
        }
    }

    @Test func aComposedRangeLoopStaysInside() async throws {
        let controller = controller()
        let view = surface()
        defer { controller.stop(view) }
        // A second, then a second and a half, overlapping by half a second:
        // two seconds, with the loop around the dip at [0.5, 1.0).
        try await loadWholeClip(controller, view, loop: 0.5...1.5, segments: [
            VideoExportSegment(start: 0, end: 1, transitionOut: .dipToBlack),
            VideoExportSegment(start: 2, end: 3.5)
        ])

        let taken = try await samples(controller, view, for: 3.5)

        #expect(wraps(taken).count >= 2, "guard: it did not loop twice")
        #expect((taken.max() ?? 9) <= 1.5 + 1.0 / 30 + 0.01, "it played past its range: \(taken.max() ?? -1)")
        #expect((taken.dropFirst(5).min() ?? -1) >= 0.49, "it played before its range")
    }

    @Test func aLoadWithoutARangeLoopsTheWholeItem() async throws {
        let controller = controller()
        let view = surface()
        defer { controller.stop(view) }
        try await loadWholeClip(controller, view, loop: 1.0...2.0)
        try await loadWholeClip(controller, view, loop: nil, segments: [
            VideoExportSegment(start: 0, end: 1.5), VideoExportSegment(start: 2, end: 3.5)
        ])
        let item = try #require(controller.debugItem(in: view))
        #expect(!item.forwardPlaybackEndTime.isValid, "the new item kept an end")

        let landings = wraps(try await samples(controller, view, for: 3.8))
        #expect(!landings.isEmpty, "guard: it never looped")
        #expect(landings.allSatisfy { $0 < 0.1 }, "the whole item wrapped to \(landings)")
    }

    @Test func clearingTheRangeLetsTheClipPlayOn() async throws {
        let controller = controller()
        let view = surface()
        defer { controller.stop(view) }
        try await loadWholeClip(controller, view, loop: 1.0...2.0)
        _ = try await samples(controller, view, for: 0.5)

        #expect(controller.setLoopRange(nil, in: view))

        let taken = try await samples(controller, view, for: 2.5)
        #expect((taken.max() ?? 0) > 2.2, "the clip still stops at the old range: \(taken.max() ?? -1)")
    }

    @Test func aPooledPlayerForgetsItsRange() async throws {
        let controller = controller(pool: 2)
        let first = surface()
        try await loadWholeClip(controller, first, loop: 1.0...2.0)
        controller.stop(first)

        let second = surface()
        defer { controller.stop(second) }
        try await loadWholeClip(controller, second, loop: nil)
        let landings = wraps(try await samples(controller, second, for: 4.6))

        #expect(!landings.isEmpty, "guard: the second clip never looped")
        #expect(landings.allSatisfy { $0 < 0.1 }, "a reused player wrapped to the old range: \(landings)")
    }

    /// ⚠️ **THE TABLE SHRINKS WITH THE LOANS.** A player the pool has no room
    /// for is dropped, and an entry keyed by it would outlive it.
    @Test func aStoppedPlayerLeavesNoLoopBehind() async throws {
        let controller = controller()
        let view = surface()
        try await loadWholeClip(controller, view, loop: 1.0...2.0)
        #expect(controller.debugLoopEntryCount == 1, "guard: the arrangement was not recorded")

        controller.stop(view)

        #expect(controller.debugLoopEntryCount == 0, "a stopped player is still recorded")
    }

    @Test func aLandingOutsideItsRangeStartsInside() async throws {
        let controller = controller()
        let view = surface()
        defer { controller.stop(view) }
        try await loadWholeClip(controller, view, loop: 1.0...2.0, at: 3.2)

        let taken = try await samples(controller, view, for: 0.6)

        let first = try #require(taken.first)
        #expect(first >= 0.99 && first <= 2.05, "the clip began outside its range, at \(first)")
        #expect((taken.max() ?? 9) <= 2.0 + 1.0 / 30 + 0.01, "it played past its range: \(taken.max() ?? -1)")
    }

    @Test func aPausedClipStaysPausedWhenARangeIsSet() async throws {
        let controller = controller()
        let view = surface()
        defer { controller.stop(view) }
        try await loadWholeClip(controller, view, loop: nil)
        controller.setPaused(true, in: view)

        #expect(controller.setLoopRange(1.0...2.0, in: view))
        _ = try await samples(controller, view, for: 0.5)

        #expect(controller.isPaused(in: view) == true, "setting a range started the clip")
        let head = try #require(controller.playheadSeconds(in: view))
        #expect(abs(head - 1.0) < 0.05, "the paused clip is at \(head), not at the range's start")
    }

    /// ⚠️ **A FILE NEVER LOOPS A RANGE.** A file nothing can be arranged from —
    /// here, one with no picture — is played as it is, and its seconds are not
    /// an arrangement's.
    @Test func aFailedBuildIgnoresTheRange() async throws {
        let controller = controller()
        let view = surface()
        defer { controller.stop(view) }
        try await loadWholeClip(controller, view, loop: 1.0...2.0, segments: [
            VideoExportSegment(start: 0, end: 1.5), VideoExportSegment(start: 2, end: 3.5)
        ], picture: false)
        let item = try #require(controller.debugItem(in: view))

        #expect(!item.forwardPlaybackEndTime.isValid, "the file took the range")
        #expect(controller.setLoopRange(1.0...2.0, in: view) == false, "the file took a range afterwards")
        #expect(!item.forwardPlaybackEndTime.isValid)
    }

    @Test func aRangeTooShortToLoopIsRefused() async throws {
        let controller = controller()
        let view = surface()
        defer { controller.stop(view) }
        try await loadWholeClip(controller, view, loop: nil)
        #expect(controller.setLoopRange(1.0...1.05, in: view) == false)
        #expect(controller.setLoopRange(1.0...1.1, in: view))
    }

    @Test func aRangeOnNothingIsRefused() {
        let controller = controller()
        #expect(controller.setLoopRange(0...1, in: surface()) == false)
    }
}
