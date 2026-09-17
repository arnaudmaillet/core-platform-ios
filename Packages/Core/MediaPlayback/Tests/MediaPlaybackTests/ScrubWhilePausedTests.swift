import AVFoundation
import Foundation
import Testing
@testable import MediaPlayback

/// **SEEKING A PAUSED PLAYER, AND THEN LETTING IT GO.**
///
/// ⚠️ **THE PAUSE ANCHOR EXISTS TO UNDO DRIFT, AND IT WAS UNDOING SCRUBS.**
/// `setPaused(true)` files where the picture was, because an HLS stream
/// re-anchors its timebase while stopped and comes back somewhere else —
/// measured at 5x to 17.5x. `setPaused(false)` pins it back whenever the two
/// have drifted more than 0.15s.
///
/// A scrub is exactly that shape and is not drift: pause, seek somewhere else,
/// resume. The resume found a difference of seconds and dragged the clip back to
/// where the finger STARTED. Reported from the editor's timeline as "the video
/// goes back to its starting point instead of carrying on from the cursor".
///
/// ⚠️ **AND THIS SUITE DRIVES A REAL PLAYER OVER A REAL FILE, WHICH
/// `PlayheadResumeTests` DELIBERATELY DOES NOT.** That one asserts the ledger
/// because its stub URL has no duration, so its playhead never leaves zero and a
/// test written through `play` would pass whatever the rules said. The bug here
/// is entirely in what a real `seek` does to a real anchor, so a stub cannot see
/// it: `seek(toFraction:in:)` returns early on an item with no duration.
@MainActor
struct ScrubWhilePausedTests {
    private struct Passthrough: VideoSource {
        func playableURL(for url: URL) async throws -> URL { url }
    }

    private func clip(seconds: Double = 3) async throws -> URL {
        try await PlaceholderVideoFetcher(durationSeconds: seconds)
            .playableURL(for: URL(string: "mock://video/scrub?w=240&h=240")!)
    }

    /// Binds a real player to a surface and waits for the item to report a
    /// length — `playhead` and `seek` both refuse until it does.
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

    @Test func aSeekMovesAPausedPlayer() async throws {
        let (controller, surface) = try await bound(try await clip())
        _ = try #require(controller.playhead(in: surface), "guard: the item reported a length")

        controller.setPaused(true, in: surface)
        controller.seek(toFraction: 0.75, in: surface)
        try await Task.sleep(for: .milliseconds(300))

        let head = try #require(controller.playhead(in: surface))
        #expect(abs(head.fraction - 0.75) < 0.12, "the seek did not land: \(head)")
    }

    /// ⚠️ **THE ONE THAT WAS RED.** Resuming must leave the scrubbed position
    /// alone. With the stale anchor in place this came back at ~0, because the
    /// drift between "where the finger went down" and "where it let go" is the
    /// whole length of the scrub.
    @Test func resumingAfterAScrubCarriesOnFromTheScrubbedPosition() async throws {
        let (controller, surface) = try await bound(try await clip())
        _ = try #require(controller.playhead(in: surface), "guard: the item reported a length")

        controller.setPaused(true, in: surface)
        controller.seek(toFraction: 0.75, in: surface)
        try await Task.sleep(for: .milliseconds(300))
        let scrubbed = try #require(controller.playhead(in: surface)).fraction
        #expect(abs(scrubbed - 0.75) < 0.12, "guard: the scrub landed before we resumed")

        controller.setPaused(false, in: surface)
        try await Task.sleep(for: .milliseconds(300))

        let head = try #require(controller.playhead(in: surface))
        #expect(head.fraction > 0.6,
                "resuming dragged the clip back to where the scrub started: \(head)")
    }

    /// The witness: with no seek in between, the anchor still does its job. A
    /// fix that simply deleted the re-pin would pass the test above and lose the
    /// behaviour that test exists to protect.
    @Test func aPauseWithNoSeekStillFilesAnAnchor() async throws {
        let (controller, surface) = try await bound(try await clip())
        #expect(controller.debugPausedAnchorCount == 0, "guard: nothing filed yet")

        controller.setPaused(true, in: surface)

        #expect(controller.debugPausedAnchorCount == 1,
                "the anchor is gone, and with it the HLS drift correction")
    }
}

/// **A FINGER ASKS SIXTY TIMES A SECOND, AND A SEEK CANCELS THE ONE BEFORE IT.**
///
/// ⚠️ **THIS IS THE MEASUREMENT BEHIND THE CHASE.** `AVPlayer.seek` kills the
/// request still running when a new one arrives. A scrub produces one request
/// per vsync, so without a queue almost every one of them is cancelled: the
/// picture sits still while the finger moves and then jumps to wherever it
/// stopped. Reported from the device as "if I scroll fast the video jumps
/// instead of progressing frame by frame, and worse in reverse".
@MainActor
struct ChasedSeekTests {
    private struct Passthrough: VideoSource {
        func playableURL(for url: URL) async throws -> URL { url }
    }

    private func bound() async throws -> (VideoPlaybackController, VideoRenderView) {
        let file = try await PlaceholderVideoFetcher(durationSeconds: 3)
            .playableURL(for: URL(string: "mock://video/chase?w=240&h=240")!)
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

    /// ⚠️ **NO REQUEST IS EVER THROWN AWAY.** Each is either seeked to or
    /// superseded by a newer one that has not been issued yet — never issued and
    /// then killed, which is the wasted decode that made scrubbing lurch.
    /// ⚠️ **THE CLIP IS STOPPED FIRST, AND WITHOUT THAT THIS TEST FLICKERS.**
    /// `finished == false` does not only mean "a later seek killed this one" —
    /// a player that is RUNNING can interrupt a seek for reasons of its own, and
    /// the fixture is three seconds long, so a burst of reverse seeks over a
    /// playing clip reported one uncancelled-by-me cancellation about one run in
    /// three. Pausing removes everything from the picture except the thing under
    /// test: whether asking again cancels what was already asked.
    @Test func aBurstOfSeeksCancelsNothing() async throws {
        let (controller, surface) = try await bound()
        _ = try #require(controller.playhead(in: surface), "guard: the item reported a length")
        controller.setPaused(true, in: surface)

        for step in 0..<24 {
            controller.seek(
                toFraction: Double(step) / 24, in: surface, toleranceSeconds: 0.05
            )
            #expect(controller.debugSeeksInFlight <= 1,
                    "two seeks at once is one of them being cancelled")
            // ⚠️ **THE QUEUED TARGET, NOT THE COUNT.** `chased` holds one entry
            // per PLAYER, so with a single-player fixture `count <= 1` is
            // structurally true whatever the implementation does — a backlog
            // regression would make the VALUE an array and the outer count would
            // still read 1. What can be wrong is which position is queued: it
            // must be the latest asked for, never an earlier one held back.
            if let queued = controller.debugChasedTarget(in: surface) {
                #expect(abs(queued - 3 * Double(step) / 24) < 0.01,
                        "the queue is holding an older position: \(queued)")
            }
        }
        try await Task.sleep(for: .milliseconds(600))

        #expect(controller.debugSeeksCancelled == 0,
                "\(controller.debugSeeksCancelled) seeks were issued and then killed")
        #expect(controller.debugSeeksLanded > 0, "guard: seeks were actually run")
    }

    /// And the last thing asked for is where the picture ends up — a queue that
    /// kept the FIRST request would leave the film behind the finger for good.
    @Test func theLastPositionAskedForIsTheOneItLandsOn() async throws {
        let (controller, surface) = try await bound()
        _ = try #require(controller.playhead(in: surface))
        controller.setPaused(true, in: surface)

        for step in 0..<12 {
            controller.seek(toFraction: Double(step) / 12, in: surface, toleranceSeconds: 0.05)
        }
        try await Task.sleep(for: .milliseconds(700))

        let head = try #require(controller.playhead(in: surface))
        #expect(abs(head.fraction - 11.0 / 12.0) < 0.1,
                "it settled at \(head.fraction), not where the finger stopped")
    }

    /// Scrubbing backwards is the expensive direction — every frame means
    /// decoding forward from the previous keyframe — and it must not be the one
    /// that strands requests.
    @Test func scrubbingBackwardsCancelsNothingEither() async throws {
        let (controller, surface) = try await bound()
        _ = try #require(controller.playhead(in: surface))
        // Stopped, for the reason the forward burst above gives.
        controller.setPaused(true, in: surface)

        for step in stride(from: 23, through: 0, by: -1) {
            controller.seek(
                toFraction: Double(step) / 24, in: surface, toleranceSeconds: 0.05
            )
        }
        try await Task.sleep(for: .milliseconds(600))

        // ⚠️ **THE WITNESS ITS FORWARD TWIN HAD AND THIS ONE DID NOT.** With
        // `seek` neutered to `return`, nothing is cancelled and nothing is
        // coalesced either — both assertions below pass on a completely dead
        // seek path. Reported by a review that tried exactly that.
        #expect(controller.debugSeeksLanded > 0, "guard: seeks were actually run")
        #expect(controller.debugSeeksCancelled == 0,
                "\(controller.debugSeeksCancelled) reverse seeks were killed")
        #expect(controller.debugSeeksLanded < 24,
                "every one of 24 requests was issued separately — nothing was coalesced")
    }
}
