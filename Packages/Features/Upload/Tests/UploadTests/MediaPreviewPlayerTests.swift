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
        await player.play(try await clip(), in: surface)
        for _ in 0..<400 {
            if player.playhead(in: surface) != nil { break }
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
        _ = try #require(player.playhead(in: surface), "guard: the item reported a length")

        player.seek(toFraction: 0.5, in: surface, toleranceSeconds: 0.02)

        #expect(player.debugLastSeekToleranceSeconds == 0.02,
                "got \(String(describing: player.debugLastSeekToleranceSeconds))")
    }

    /// And a loose one is passed through just as faithfully — a fix that hard-coded
    /// the tight value would pass the test above and break a fast scrub.
    @Test func aLooseToleranceIsForwardedToo() async throws {
        let (player, surface) = try await bound()
        _ = try #require(player.playhead(in: surface))

        player.seek(toFraction: 0.5, in: surface, toleranceSeconds: 0.25)

        #expect(player.debugLastSeekToleranceSeconds == 0.25)
    }

    /// The loop-back asks for 0.02 because `MediaTimelining.loopback`'s slack is
    /// 0.06: a landing further out than the slack falls back OUTSIDE the cut and
    /// asks to be moved again, every beat, forever.
    @Test func theTightestToleranceIsInsideTheLoopBacksOwnSlack() {
        let tightest = MediaTimelining.seekTolerance(movedSeconds: 0.001)
        let slack: Double = 0.06

        #expect(tightest <= slack,
                "a creeping scrub can land outside the cut and re-trigger the loop every beat")
    }
}
