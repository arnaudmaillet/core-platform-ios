import AVFoundation
import CoreVideo
import Foundation
import Testing
@testable import MediaPlayback

/// **THE EDITOR'S CANVAS READS COMPOSED FRAMES AHEAD OF ITS CLOCK.**
///
/// `ComposedFrameReader` directly, with no player: the clock is whatever time
/// the test asks for, and the frames are what an `AVAssetReader` drew through
/// `VideoCompositor` — compared, pixel for pixel, with what an image generator
/// draws through the same composition.
///
/// ⚠️ **`frame(at:)` NEVER WAITS**, so every test polls: ask, sleep a few
/// milliseconds, ask again, within a bounded time. A nil is "not yet", and only
/// a nil that outlasts the bound is an answer.
@Suite(.serialized)
struct ComposedFrameReaderTests {
    typealias RGB = ColourClipWriter.RGB

    private static let frame = 1.0 / 30

    /// A dissolve at 1s between red and blue — two seconds that need a
    /// compositor, so the arrangement has something to read.
    private func arranged(
        _ segments: [VideoExportSegment] = [
            VideoExportSegment(start: 0, end: 1, transitionOut: .dissolve),
            VideoExportSegment(start: 2, end: 3)
        ]
    ) async throws -> (VideoExporter.Arrangement, ComposedVideo) {
        let file = try await ColourClipWriter.clip()
        let arrangement = try await VideoExporter.arrangement(
            of: AVURLAsset(url: file), cut: segments, orientation: .whenComposited
        )
        let composed = try #require(arrangement.composed, "guard: the arrangement draws nothing")
        return (arrangement, composed)
    }

    /// ⚠️ **ROUNDED TO THE NEAREST TICK, NOT TRUNCATED.** `CMTime(seconds:
    /// preferredTimescale:)` truncates, so 11/30 becomes 219/600 — a tick
    /// BEFORE the frame at 220/600 — and a clock asking for "frame 11" is
    /// rightly handed frame 10. Measured: a forward walk in thirtieths skipped
    /// every third or so frame, and the last frame was never asked for at all.
    private func time(_ seconds: Double) -> CMTime {
        CMTime(value: CMTimeValue((seconds * 600).rounded()), timescale: 600)
    }

    /// Asks for `seconds` until a frame comes back or `limit` runs out.
    private func poll(
        _ reader: ComposedFrameReader, at seconds: Double, within limit: Double = 5
    ) async throws -> (buffer: CVPixelBuffer, time: CMTime)? {
        let deadline = CACurrentMediaTime() + limit
        while CACurrentMediaTime() < deadline {
            if let frame = reader.frame(at: time(seconds)) { return frame }
            try await Task.sleep(for: .milliseconds(5))
        }
        return nil
    }

    /// Asks for `seconds` until the frame handed out is the one AT it, and
    /// returns the last frame handed out.
    ///
    /// ⚠️ **AN EARLIER ANSWER IS NOT WRONG.** Asked for a time the reader has
    /// not reached yet, it hands the newest frame it has — the surface shows
    /// something rather than nothing — and the frame of the asked time comes
    /// on a later ask.
    private func pollUntilReached(
        _ reader: ComposedFrameReader, _ seconds: Double, within limit: Double = 2
    ) async throws -> CMTime? {
        let deadline = CACurrentMediaTime() + limit
        var last: CMTime?
        while CACurrentMediaTime() < deadline {
            if let frame = reader.frame(at: time(seconds)) {
                last = frame.time
                if frame.time == time(seconds) { break }
            }
            try await Task.sleep(for: .milliseconds(5))
        }
        return last
    }

    /// Waits until the reader holds a full lookahead or has stopped, and
    /// returns how long that took.
    ///
    /// ⚠️ **GENEROUS, BECAUSE THE OTHER SUITES SHARE THE COMPOSITOR.** Suites run
    /// side by side, and an export elsewhere draws through the same
    /// `VideoCompositor` context: measured, a fresh reader once held only three
    /// frames after two seconds while `CrossTransitionTests` exported, and was
    /// still reading. Slow is not what these tests are about.
    @discardableResult
    private func settle(_ reader: ComposedFrameReader, within limit: Double = 10) async throws -> Double {
        let started = CACurrentMediaTime()
        while CACurrentMediaTime() < started + limit {
            let state = reader.debugState
            if state.frames >= ComposedFrameReader.lookahead || !state.reading { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        return CACurrentMediaTime() - started
    }

    /// One pixel of a BGRA buffer, at fractions of its size (0,0 top left).
    private func colour(of buffer: CVPixelBuffer, x: Double, y: Double) -> RGB {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let row = CVPixelBufferGetBytesPerRow(buffer)
        guard let base = CVPixelBufferGetBaseAddress(buffer)?.assumingMemoryBound(to: UInt8.self) else {
            return RGB(r: -1, g: -1, b: -1)
        }
        let at = Int(Double(height) * y) * row + Int(Double(width) * x) * 4
        return RGB(r: Int(base[at + 2]), g: Int(base[at + 1]), b: Int(base[at]))
    }

    private func distance(_ a: RGB, _ b: RGB) -> Int {
        max(abs(a.r - b.r), abs(a.g - b.g), abs(a.b - b.b))
    }

    // MARK: - What is handed out

    /// ⚠️ **THE FRAME FOR A TIME IS THE ONE AT OR JUST BEFORE IT — NOT THE
    /// NEWEST READ.** The reader runs a lookahead of frames past the clock;
    /// handing out the newest would show the picture early by up to that many
    /// frames. Asked, left to fill its lookahead, then asked again, it must
    /// still answer with the frame of the asked time — and that frame must be
    /// what the image generator draws there, transition included.
    ///
    /// ⚠️ **THE GENERATOR'S PIXELS ARE NOT THE READER'S BYTES.** The generator
    /// hands a `CGImage` that is colour-matched again on its way into the test's
    /// context; measured, the same frame read (174,95,0) from the buffer and
    /// (183,106,0) from the generator half way into the dissolve, and the cyan
    /// square 62 against 71 on red. Hence the slack — far below what a
    /// neighbouring frame of the window changes (the blend moves ~6% a frame,
    /// the plain colours by 200).
    @Test func aRequestIsAnsweredWithTheFrameAtItsTime() async throws {
        let (arrangement, composed) = try await arranged()
        // In the plain red, either side of the cut inside the window, in the
        // plain blue, and off the composition's frame grid.
        for seconds in [0.5, 0.9, 1.1, 1.5, 0.51] {
            let reader = ComposedFrameReader(composed)
            defer { reader.close() }
            _ = reader.frame(at: time(seconds))
            let waited = try await settle(reader)
            let held = reader.debugState.frames
            // ⚠️ TWO IS ENOUGH TO MAKE THE POINT — a newer frame than the one
            // asked for is there to be handed out wrongly. A slow CI runner read
            // only three of the six in the settle budget.
            #expect(held >= 2,
                    "guard: at \(seconds)s the reader read \(held) frames ahead in \(waited)s")
            let got = try #require(try await poll(reader, at: seconds), "nothing answered \(seconds)s")
            let at = got.time.seconds
            #expect(at <= seconds + 0.000_001 && seconds - at < Self.frame + 0.001,
                    "asked for \(seconds)s, handed the frame at \(at)s")
            for (x, y) in [(0.1, 0.5), (0.5, 0.5), (0.5, 0.05)] {
                let read = colour(of: got.buffer, x: x, y: y)
                let generated = try await ColourClipWriter.pixel(
                    of: arrangement.asset, composition: arrangement.videoComposition, at: seconds, x: x, y: y
                )
                #expect(distance(read, generated.colour) <= 20,
                        "at \(seconds)s (\(x),\(y)) the reader drew \(read) (its frame at \(at)s), the generator \(generated.colour)")
            }
        }
    }

    /// ⚠️ **A FRAME IS HANDED ONCE.** The display link asks every tick, faster
    /// than the film changes; handing the same buffer again would enqueue it
    /// twice.
    @Test func aFrameIsHandedOutOnce() async throws {
        let (_, composed) = try await arranged()
        let reader = ComposedFrameReader(composed)
        defer { reader.close() }
        _ = reader.frame(at: time(0.5))
        try await settle(reader)

        let first = try #require(try await poll(reader, at: 0.5), "guard: nothing answered 0.5s")
        #expect(reader.frame(at: time(0.5)) == nil, "the frame at \(first.time.seconds)s was handed out twice")
        let next = try #require(try await poll(reader, at: 0.5 + Self.frame), "guard: the next frame never came")
        #expect(next.time > first.time, "the next frame is not newer: \(next.time.seconds)s after \(first.time.seconds)s")
    }

    /// ⚠️ **A JUMP BACK RESTARTS THE READER.** A reader only goes forward; a
    /// loop wrap or a scrub back asks for film it has already passed, and must
    /// be answered with THAT film — not left waiting, and not given the stale
    /// frame from where it was.
    ///
    /// Measured answering in 38ms; the bound is three seconds because the
    /// suites around this one export through the same compositor.
    @Test func aBackwardJumpIsAnsweredFromTheNewPlace() async throws {
        let (arrangement, composed) = try await arranged([
            VideoExportSegment(start: 0, end: 1, transitionOut: .dissolve),
            VideoExportSegment(start: 2, end: 4)
        ])
        let reader = ComposedFrameReader(composed)
        defer { reader.close() }
        let late = try #require(try await poll(reader, at: 2.5), "guard: nothing answered 2.5s")
        #expect(colour(of: late.buffer, x: 0.1, y: 0.5).near(.white), "guard: 2.5s is not the file's white")

        let early = try #require(try await poll(reader, at: 0.5, within: 3), "the jump back was never answered")
        let at = early.time.seconds
        #expect(at <= 0.5 + 0.000_001 && 0.5 - at < Self.frame + 0.001, "the jump back to 0.5s handed the frame at \(at)s")
        let read = colour(of: early.buffer, x: 0.1, y: 0.5)
        let generated = try await ColourClipWriter.pixel(
            of: arrangement.asset, composition: arrangement.videoComposition, at: 0.5, x: 0.1, y: 0.5
        ).colour
        #expect(distance(read, generated) <= 20, "the jump back drew \(read), the generator \(generated)")
        #expect(read.r > read.b + 100, "the jump back is not the red it asked for: \(read)")
    }

    /// ⚠️ **PLAYED FORWARD, EVERY FRAME COMES, IN ORDER.** A display link asks
    /// once a frame; the reader must follow it without skipping film and never
    /// hand a frame out of order.
    ///
    /// ⚠️ **EACH TICK WAITS FOR ITS FRAME, SO THE LOAD ON THE MACHINE CANNOT
    /// DECIDE THE RESULT.** Paced in real time alone, with a hundred
    /// milliseconds per tick, this walk got 31 frames of 59 while another suite
    /// exported — a reader that is merely slow looks exactly like one that
    /// skips. Waiting
    /// (bounded) for each tick's frame leaves only what the reader HANDS OUT to
    /// judge; three silent ticks in a row end the walk, since a reader that
    /// has stopped answering will not start again.
    ///
    /// ⚠️ **AND THE BUDGET IS THE LEGACY LANE'S, NOT THIS MACHINE'S.** CI runs
    /// this suite a second time under `-avplayer-render`, where the player
    /// composites every frame itself and the whole run takes twice as long; at
    /// two seconds a tick the walk ended after 12 frames there and called a
    /// loaded runner a skipping reader.
    ///
    /// ⚠️ **AND THE READER IS STARTED ONCE.** A reader that restarts at every
    /// tick hands out a perfect sequence — each fresh reader's first frame is
    /// the one asked for — while decoding from a keyframe every frame. Measured
    /// with the frames kept newest-first: every frame in order, and a restart
    /// per tick. Only the generation shows it.
    @Test func playingForwardHandsFramesInOrder() async throws {
        let (_, composed) = try await arranged()
        let reader = ComposedFrameReader(composed)
        defer { reader.close() }

        var handed: [Double] = []
        var silent = 0
        let steps = 59
        for step in 0..<steps where silent < 3 {
            try await Task.sleep(for: .milliseconds(33))
            if let frame = try await poll(reader, at: Double(step) / 30, within: 8) {
                handed.append(frame.time.seconds)
                silent = 0
            } else {
                silent += 1
            }
        }
        #expect(handed.count >= steps - 2, "only \(handed.count) of \(steps) ticks got a frame")
        let pairs = Array(zip(handed, handed.dropFirst()))
        let backwards = pairs.filter { $0.1 <= $0.0 }
        #expect(backwards.isEmpty, "frames out of order: \(backwards)")
        let gaps = pairs.dropFirst(5).filter { $0.1 - $0.0 > 2 * Self.frame + 0.001 }
        #expect(gaps.isEmpty, "frames skipped: \(gaps.map { ($0.0, $0.1) })")
        #expect((handed.last ?? 0) >= 1.9, "the reader never reached the end: \(handed.last ?? -1)")
        #expect(reader.debugState.generation == 1,
                "playing forward restarted the reader \(reader.debugState.generation - 1) times")
    }

    // MARK: - Falling behind

    /// ⚠️ **A READER GIVEN UP FOR FALLING BEHIND STARTS AHEAD OF THE CLOCK, NOT
    /// ON IT.** Started where the clock stands, its first frame arrives only
    /// after a decode from the keyframe — by which time the clock has moved that
    /// far on again, so it is behind again and gives up again. Measured on a
    /// loaded machine before this: thirty-one restarts and a lag that reached
    /// 9.1s, with the picture frozen the whole time, which is how a slow machine
    /// came to look like a dead player.
    ///
    /// The clock is simply left alone here while real time passes: the reader
    /// fills its lookahead and waits, so it ends up a long way behind without
    /// anything having jumped.
    @Test func aCatchUpStartsAheadOfTheClock() async throws {
        let (_, composed) = try await arranged([
            VideoExportSegment(start: 0, end: 2, transitionOut: .dissolve),
            VideoExportSegment(start: 2, end: 4)
        ])
        let reader = ComposedFrameReader(composed)
        defer { reader.close() }
        _ = try #require(try await poll(reader, at: 0, within: 8), "guard: nothing answered the start")
        // What a start costs is measured, not guessed — the lead is only as
        // good as that number.
        #expect(reader.debugStart.cost > 0, "the first start's cost was never noted")
        reader.debugSetLastStartCost(0.5)
        let generation = reader.debugState.generation

        try await Task.sleep(for: .seconds(3))
        _ = reader.frame(at: time(2.6))

        let started = reader.debugStart.at.seconds
        #expect(reader.debugState.generation > generation, "the reader was not given up at all")
        #expect(abs(started - 3.1) < 0.01, "a catch-up started at \(started)s, not 0.5s ahead of 2.6s")
    }

    /// ⚠️ **AND A JUMP LANDS ON THE MOMENT IT ASKS FOR.** A seek, a scrub or a
    /// wrap is the author naming a moment; handing them a later one would be
    /// answering a different question. Only the catch-up aims ahead.
    @Test func aJumpStartsOnTheMomentItAsksFor() async throws {
        let (_, composed) = try await arranged()
        let reader = ComposedFrameReader(composed)
        defer { reader.close() }
        _ = try #require(try await poll(reader, at: 0, within: 8), "guard: nothing answered the start")
        reader.debugSetLastStartCost(0.5)

        _ = reader.frame(at: time(1.2))

        #expect(abs(reader.debugStart.at.seconds - 1.2) < 0.01,
                "a jump started at \(reader.debugStart.at.seconds)s")
    }

    /// The lead itself: what the last start cost, never under the throttle and
    /// never over a second.
    @Test func theLeadIsWhatTheLastStartCost() {
        func lead(_ cost: CFTimeInterval) -> Double {
            (ComposedFrameReader.catchUpStart(for: CMTime(value: 600, timescale: 600), lastStartCost: cost)
                - CMTime(value: 600, timescale: 600)).seconds
        }
        #expect(abs(lead(0.4) - 0.4) < 0.001)
        #expect(abs(lead(0) - ComposedFrameReader.restartThrottle) < 0.001, "a lead of nothing is no lead")
        #expect(abs(lead(4) - 1) < 0.001, "one slow start threw away four seconds of film")
    }

    // MARK: - Stopping

    /// ⚠️ **AT THE END IT STOPS, AND DOES NOT SPIN.** A reader that has run
    /// out is at the end of the film, not behind the clock: restarting it for
    /// a time past the end would find nothing, run out again, and restart
    /// again, every tick.
    @Test func pastTheEndItStops() async throws {
        let (_, composed) = try await arranged()
        let reader = ComposedFrameReader(composed)
        defer { reader.close() }
        _ = try #require(try await poll(reader, at: 1.8, within: 8), "guard: nothing answered 1.8s")
        let last = try #require(
            try await pollUntilReached(reader, 2 - Self.frame, within: 8),
            "guard: nothing answered the last frame"
        )
        try #require(last == time(2 - Self.frame), "guard: the last frame handed out is at \(last.seconds)s")

        // ⚠️ THE FIRST REQUEST PAST THE END IS A JUMP, and a reader may
        // restart for it; what it must not do is keep restarting while the
        // clock runs on from there. So the count starts once that request
        // has settled, and the clock then advances at the pace it plays.
        var answered: [Double] = []
        if let frame = reader.frame(at: time(2.5)) { answered.append(frame.time.seconds) }
        let deadline = CACurrentMediaTime() + 5
        while reader.debugState.reading, CACurrentMediaTime() < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(!reader.debugState.reading, "the reader is still reading after the end")

        let generation = reader.debugState.generation
        for step in 1...50 {
            try await Task.sleep(for: .milliseconds(10))
            if let frame = reader.frame(at: time(2.5 + Double(step) / 100)) {
                answered.append(frame.time.seconds)
            }
        }
        #expect(answered.isEmpty, "past the end it handed out \(answered)")
        #expect(reader.debugState.generation == generation,
                "past the end it restarted \(reader.debugState.generation - generation) times")
        #expect(!reader.debugState.reading, "past the end it started reading again")
    }

    /// A reader asked first for a time past the end finds nothing and stops.
    @Test func aReaderStartedPastTheEndStops() async throws {
        let (_, composed) = try await arranged()
        let reader = ComposedFrameReader(composed)
        defer { reader.close() }

        var answered: [Double] = []
        for step in 0..<50 {
            if let frame = reader.frame(at: time(3 + Double(step) / 100)) {
                answered.append(frame.time.seconds)
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(answered.isEmpty, "past the end it handed out \(answered)")
        #expect(reader.debugState.generation == 1, "it restarted \(reader.debugState.generation - 1) times")
        #expect(!reader.debugState.reading, "it is still reading")
    }

    /// ⚠️ **CLOSED IS CLOSED.** A surface that has moved to another item must
    /// never be handed a frame of this one — not one already read, not one a
    /// new request would read.
    @Test func closeEndsEveryLaterRequest() async throws {
        let (_, composed) = try await arranged()
        let reader = ComposedFrameReader(composed)
        _ = reader.frame(at: time(0.5))
        try await settle(reader)
        _ = try #require(try await poll(reader, at: 0.5), "guard: nothing answered 0.5s")
        #expect(reader.debugState.frames > 1, "guard: nothing was read ahead to be handed out")

        reader.close()
        let generation = reader.debugState.generation

        #expect(reader.frame(at: time(0.5 + Self.frame)) == nil, "a frame read before the close was handed out")
        #expect(reader.frame(at: time(0.5 + 2 * Self.frame)) == nil, "a frame read before the close was handed out")
        #expect(try await poll(reader, at: 1.5, within: 0.3) == nil, "a request after the close was read and answered")
        #expect(try await poll(reader, at: 0.2, within: 0.3) == nil, "a jump back after the close was answered")
        #expect(reader.debugState.frames == 0, "the closed reader still holds \(reader.debugState.frames) frames")
        #expect(reader.debugState.generation == generation, "the closed reader restarted")
    }

    /// ⚠️ **A READER THAT CANNOT START IS TRIED AGAIN.** It used to mark itself
    /// done, and a paused canvas stayed blank until the next seek — which a
    /// paused clip may never get. Nobody asks for another time here.
    @Test func aReaderThatCouldNotStartIsTriedAgain() async throws {
        let (_, composed) = try await arranged()
        let reader = ComposedFrameReader(composed)
        defer { reader.close() }
        reader.debugFailNextStarts(1)

        _ = reader.frame(at: time(0.5))
        var failed = false
        for _ in 0..<400 where !failed {
            try await Task.sleep(for: .milliseconds(5))
            failed = !reader.debugState.reading
        }
        try #require(failed, "guard: the first reader did not fail")

        // ⚠️ **THE BUDGET IS THE LEGACY LANE'S.** The retry waits half a second
        // and then decodes from the keyframe; that costs 0.4 to 1.5s here and
        // several times as much on the CI runner that composites every frame
        // through the player. At ten seconds this called that runner a reader
        // that never tried again.
        let got = try await poll(reader, at: 0.5, within: 30)
        #expect(got != nil, "the reader never tried again")
        #expect(reader.debugState.generation == 2, "tried \(reader.debugState.generation - 1) times")
    }

}
