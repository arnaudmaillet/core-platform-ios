import MediaPlayback
import Testing
import UIKit
@testable import Upload

/// **THE REAL ADAPTER, ASKED DIRECTLY.**
///
/// ⚠️ **EVERY OTHER TEST OF THIS SEAM READS A STUB, AND A STUB CANNOT SEE AN
/// ADAPTER THAT DROPS AN ARGUMENT.** `MediaPreviewPlayer.seek` accepted
/// `toleranceSeconds` and called `controller.seek(toFraction:in:)` without it —
/// no warning, no error, and the charter-T7 assertions in
/// `MediaEditorTimelineTests` stayed green throughout, because they read the
/// value off `StubPreview`, which records it faithfully. The repository's own
/// `laundered-assertion-trap` wearing an adapter: the assertion was made on
/// something that repeats the job rather than on the thing that does it.
///
/// This file exists so the ONE implementation that ships has a test of its own.
@MainActor
struct MediaPreviewPlayerTests {
    private func clip(seconds: Double = 2) async throws -> URL {
        try await PlaceholderVideoFetcher(durationSeconds: seconds)
            .playableURL(for: URL(string: "mock://video/adapter?w=160&h=160")!)
    }

    private func bound() async throws -> (MediaPreviewPlayer, VideoRenderView) {
        let player = MediaPreviewPlayer()
        let surface = VideoRenderView()
        surface.frame = CGRect(x: 0, y: 0, width: 80, height: 80)
        await player.load(VideoExportPlan(sourceURL: try await clip()), in: surface) {
            VideoLoadLanding(seconds: 0)
        }
        for _ in 0..<400 {
            if player.debugItemSeconds(in: surface) != nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        return (player, surface)
    }

    /// ⚠️ **CHARTER T7 LIVES OR DIES HERE.** A creeping finger asks for 0.02 so
    /// the picture follows it frame by frame; 0.25 lands on the nearest keyframe,
    /// which on a two-second GOP means the picture does not move at all while the
    /// film scrolls under it.
    @Test func theTolerancePassedInIsTheToleranceTheSeekUses() async throws {
        let (player, surface) = try await bound()
        _ = try #require(player.debugItemSeconds(in: surface), "guard: the item reported a length")

        player.seek(toSeconds: 1, in: surface, toleranceSeconds: 0.02)

        #expect(player.debugLastSeekToleranceSeconds == 0.02,
                "got \(String(describing: player.debugLastSeekToleranceSeconds))")
    }

    /// And a loose one is passed through just as faithfully — a fix that hard-coded
    /// the tight value would pass the test above and break a fast scrub.
    @Test func aLooseToleranceIsForwardedToo() async throws {
        let (player, surface) = try await bound()
        _ = try #require(player.debugItemSeconds(in: surface))

        player.seek(toSeconds: 1, in: surface, toleranceSeconds: 0.25)

        #expect(player.debugLastSeekToleranceSeconds == 0.25)
    }

    /// ⚠️ **THE ARRANGEMENT REACHES THE CONTROLLER.** The editor's suites read
    /// what a STUB was handed; only this can say the one adapter that ships
    /// passes the plan on rather than, say, the file alone — which would look
    /// exactly like a working preview of an uncut clip.
    /// ⚠️ **THE LOOP IS FORWARDED BOTH WAYS IN** — with a landing, and on its
    /// own — and taken away again: an adapter that dropped either would leave
    /// the row looping nothing, and every editor test green.
    @Test func theLoopReachesThePlayer() async throws {
        let player = MediaPreviewPlayer()
        let surface = VideoRenderView()
        surface.frame = CGRect(x: 0, y: 0, width: 80, height: 80)
        defer { player.stop(surface) }
        await player.load(
            VideoExportPlan(sourceURL: try await clip(seconds: 4), segments: [
                VideoExportSegment(start: 0, end: 2), VideoExportSegment(start: 2, end: 4)
            ]),
            in: surface
        ) { VideoLoadLanding(seconds: 1, loop: 1...3) }
        #expect(player.debugItemEnd(in: surface).map { abs($0 - 3) < 0.01 } == true,
                "the landing's loop was dropped: \(String(describing: player.debugItemEnd(in: surface)))")

        player.setLoopRange(0.5...1.5, in: surface)
        #expect(player.debugItemEnd(in: surface).map { abs($0 - 1.5) < 0.01 } == true,
                "the new range was dropped: \(String(describing: player.debugItemEnd(in: surface)))")

        player.setLoopRange(nil, in: surface)
        #expect(player.debugItemEnd(in: surface) == nil, "the range was never taken away")
    }

    @Test func anArrangementReachesThePlayerAsOneItem() async throws {
        let player = MediaPreviewPlayer()
        let surface = VideoRenderView()
        surface.frame = CGRect(x: 0, y: 0, width: 80, height: 80)

        await player.load(
            VideoExportPlan(sourceURL: try await clip(), segments: [
                VideoExportSegment(start: 1, end: 2, speed: 2),
                VideoExportSegment(start: 0, end: 1)
            ]),
            in: surface
        ) { VideoLoadLanding(seconds: 0) }

        var length: Double?
        for _ in 0..<400 {
            length = player.debugItemSeconds(in: surface)
            if length != nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let played = try #require(length, "the item never reported a length")
        #expect(abs(played - 1.5) < 0.02, "the player is running \(played)s, not the 1.5s arrangement")
    }
}
