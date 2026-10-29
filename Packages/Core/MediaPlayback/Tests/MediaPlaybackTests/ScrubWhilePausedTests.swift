import AVFoundation
import Foundation
import Testing
@testable import MediaPlayback

/// A look budget, not a deadline (#1084): counts this test's own looks, so a
/// starved runner only makes it slower, and stops as soon as `condition`
/// holds. Its result is always asserted.
@MainActor
private func settle(_ condition: () -> Bool) async -> Bool {
    for _ in 0..<6_000 {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return condition()
}

/// Returns once the clip in `surface` has no seek in flight and none queued:
/// the controller's own release seam, awaited where a fixed sleep used to
/// stand for "the seeks landed" (#1084: 600 ms was not enough on a starved
/// runner). With nothing in flight it returns at once, so a dead seek path
/// still fails the landed guard that follows.
@MainActor
private func seeksSettled(_ controller: VideoPlaybackController, in surface: VideoRenderView) async {
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
        controller.whenSeeksSettle(in: surface) { continuation.resume() }
    }
}

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
        try #require(await settle { controller.playhead(in: surface) != nil }, "the item never reported a length")
        return (controller, surface)
    }

    private static func seconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }

    @Test func aSeekMovesAPausedPlayer() async throws {
        let (controller, surface) = try await bound(try await clip())
        _ = try #require(controller.playhead(in: surface), "guard: the item reported a length")

        controller.setPaused(true, in: surface)
        controller.seek(toFraction: 0.75, in: surface)
        await seeksSettled(controller, in: surface)

        let head = try #require(controller.playhead(in: surface))
        #expect(abs(head.fraction - 0.75) < 0.12, "the seek did not land: \(head)")
    }

    /// ⚠️ **THE ONE THAT WAS RED.** Resuming must leave the scrubbed position
    /// alone. With the stale anchor in place this came back at ~0, because the
    /// drift between "where the finger went down" and "where it let go" is the
    /// whole length of the scrub.
    ///
    /// ⚠️ **A STRETCH THAT CROSSES THE LOOP'S END MEASURES THE RESTART, NOT
    /// THE SCRUB (#1873).** On the 3 s fixture, a scrub to 0.75 left 0.75 s
    /// before the end; a starved "300 ms" ran 1.26 s, crossed it, and the
    /// head came back 0.35 s late: the item holds at its end until the
    /// loop's seek to zero runs on the main queue (#1405), and that hold is
    /// lost time. So this test plays a longer clip and scrubs to its middle,
    /// with 6 s of playback before any loop: the
    /// drag-back it guards is the scrub's whole length, 4 s.
    @Test func resumingAfterAScrubCarriesOnFromTheScrubbedPosition() async throws {
        let duration = Self.longClip
        let scrubTo = 0.4
        let (controller, surface) = try await bound(try await clip(seconds: duration))
        _ = try #require(controller.playhead(in: surface), "guard: the item reported a length")

        controller.setPaused(true, in: surface)
        controller.seek(toFraction: scrubTo, in: surface)
        await seeksSettled(controller, in: surface)
        let scrubbed = try #require(controller.playhead(in: surface)).fraction
        #expect(abs(scrubbed - scrubTo) < 0.12, "guard: the scrub landed before we resumed")

        controller.setPaused(false, in: surface)
        // ⚠️ THE CLOCK STARTS WHEN THE PLAYER PLAYS, NOT AT THE CALL (#1405,
        // develop d485a18c): on a starved runner the rate took ~1.9 s to land
        // after `setPaused(false)`, and the head, still on the scrubbed
        // frame, read as 1.9 s behind.
        //
        // ⚠️ AND FROM WHERE THE HEAD WAS THEN, NOT FROM THE SCRUB (#1405,
        // develop a60f986f): the item's timebase can run before
        // `timeControlStatus` reaches the main thread, and CI read the head
        // 0.257 s AHEAD of a clock started on the status. Nor from the first
        // look where the head moved: a resume can nudge it a frame or two
        // before it plays (measured: 0.05 s of advance after 0.31 s). The
        // player's own head at the first look that sees it playing is the
        // start; the drag-back this suite guards is seconds, not a fraction.
        var resumed: (head: Double, at: ClosedRange<ContinuousClock.Instant>)?
        for _ in 0..<6_000 {
            if controller.isPlayingForReal(in: surface) {
                let before = ContinuousClock.now
                let head = try #require(controller.playhead(in: surface)).fraction
                resumed = (head, before...ContinuousClock.now)
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        let (start, startedAt) = try #require(resumed, "the player never played after the resume")
        #expect(abs(start - scrubbed) * duration < 1,
                "resuming dragged the clip back to where the scrub started: \(start) after a scrub to \(scrubbed)")
        // Not a wait for something to happen: a stretch of playback, read back
        // against the time it actually took (below), however long that was.
        try await Task.sleep(for: .milliseconds(300))
        var reading = try read(controller, surface, playingSince: startedAt)
        // ⚠️ NEVER BETWEEN THE ITEM'S END AND THE LOOP'S RESTART (#1405). The
        // loop is `actionAtItemEnd = .none` and a seek to zero on the end
        // notification, run on the main queue: until that seek runs, the item
        // holds at its end. On a starved runner the hold lasted ~0.6 s, and CI
        // read 3.0 s of a 3.0 s clip where 0.61 s was due. A reading at the end
        // is the restart still pending, not a place on the loop, so it is read
        // again once the loop has restarted, each look timed on its own. A
        // loop that never restarts still fails: it holds there through every
        // look, and that is far off the loop.
        for _ in 0..<600 where reading.head.fraction >= Self.heldAtTheEnd {
            try await Task.sleep(for: .milliseconds(10))
            reading = try read(controller, surface, playingSince: startedAt)
        }
        let (head, readFrom, readBy) = reading

        // ⚠️ AGAINST THE TIME THE TEST ACTUALLY SPENT, not `fraction > 0.6`
        // (#599): a starved "300 ms" ran ~2.4 s on CI. Dragged back to where
        // the scrub started, the clip is off by the scrub's length whatever
        // the elapsed time.
        #expect(TimingTolerance.isOnLoop(
            head.fraction * duration, start: start * duration,
            elapsed: Self.seconds(readFrom)...Self.seconds(readBy), period: duration, slack: 0.25
        ), "the clip did not play on from where it resumed (\(start)): \(head) after \(readFrom)…\(readBy)")
    }

    /// The fixture's length (`clip()`'s default).
    private static let duration = 3.0

    /// The scrub-and-resume test's clip: long enough that a scrub to 0.4
    /// leaves 6 s of playback before the loop's end, past the slowest
    /// "300 ms" CI has measured (2.4 s, #599).
    private static let longClip = 10.0

    /// A playhead this close to 1 is the item held at its end, waiting for
    /// the loop's seek to zero: closer than half a frame of the 30 fps fixture.
    private static let heldAtTheEnd = 0.995

    /// The playhead, and how long the player had been playing when it was
    /// read: at least from its latest possible start (`start.upperBound`) to
    /// just before the read, at most from its earliest (`start.lowerBound`) to
    /// just after.
    private func read(
        _ controller: VideoPlaybackController, _ surface: VideoRenderView,
        playingSince start: ClosedRange<ContinuousClock.Instant>
    ) throws -> (head: (fraction: Double, seconds: Double), from: Duration, by: Duration) {
        let before = ContinuousClock.now
        let head = try #require(controller.playhead(in: surface))
        return (head, before - start.upperBound, ContinuousClock.now - start.lowerBound)
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
        try #require(await settle { controller.playhead(in: surface) != nil }, "the item never reported a length")
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
        await seeksSettled(controller, in: surface)

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
        await seeksSettled(controller, in: surface)

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
        // The last reverse seek's landing, awaited: a fixed 600 ms ran out
        // before the FIRST one landed on a starved runner (#1084).
        await seeksSettled(controller, in: surface)

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

    // MARK: - Letting go

    /// Nothing in flight: the release has nothing to wait for.
    @Test func settlingWithNoSeekRunsAtOnce() async throws {
        let (controller, surface) = try await bound()
        var ran = false
        controller.whenSeeksSettle(in: surface) { ran = true }
        #expect(ran)
        // And a surface with no player at all does not strand its caller.
        var ranUnbound = false
        controller.whenSeeksSettle(in: VideoRenderView()) { ranUnbound = true }
        #expect(ranUnbound)
    }

    /// ⚠️ THE RELEASE WAITS FOR THE LAST SEEK, and when it runs the picture is
    /// where the finger lifted — exactly, at zero tolerance. Resuming before
    /// the landing played from wherever the player happened to be.
    @Test func settlingWaitsForTheLastSeekToLand() async throws {
        let (controller, surface) = try await bound()
        _ = try #require(controller.playhead(in: surface))
        controller.setPaused(true, in: surface)

        for step in 0..<12 {
            controller.seek(toFraction: Double(step) / 24, in: surface, toleranceSeconds: 0)
        }
        controller.seek(toFraction: 0.6, in: surface, toleranceSeconds: 0)
        var landedAt: Double?
        var inFlightWhenRun = -1
        controller.whenSeeksSettle(in: surface) {
            landedAt = controller.playhead(in: surface)?.fraction
            inFlightWhenRun = controller.debugSeeksInFlight
        }
        #expect(landedAt == nil, "it ran before the seeks it was waiting for")
        try #require(await settle { landedAt != nil }, "the release was never let go")
        let head = try #require(landedAt)
        #expect(abs(head - 0.6) < 0.02, "it ran with the picture at \(head), not at 0.6")
        #expect(inFlightWhenRun == 0)
    }
}
