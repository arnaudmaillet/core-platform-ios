import AVFoundation
import CoreMedia
import CoreVideo
import os

/// An arrangement and the composition that draws it, as the preview needs them.
///
/// ⚠️ **`@unchecked`, AND ONLY BECAUSE NOTHING MUTATES IT AFTER IT IS MADE.** The
/// asset is an `AVMutableComposition`, which is explicitly not `Sendable`; it is
/// built by `VideoExporter.arrangement`, handed here, and never touched again
/// by anyone but the readers this type starts.
public final class ComposedVideo: @unchecked Sendable {
    let asset: AVAsset
    /// The video tracks the composition reads — asked once, where the asset
    /// was built, so no reader has to load them.
    let tracks: [AVAssetTrack]
    let composition: AVVideoComposition
    /// Where the composition's pictures end — past it a reader finds nothing,
    /// and that is not a failure.
    let end: CMTime
    /// The board `composition`'s instructions read the whole look from — what
    /// a live look change is written to. Nil when it was built without one.
    let live: VideoLiveLook?

    init(asset: AVAsset, tracks: [AVAssetTrack], composition: AVVideoComposition, live: VideoLiveLook? = nil) {
        self.asset = asset
        self.tracks = tracks
        self.composition = composition
        self.end = composition.instructions.map(\.timeRange.end).max() ?? .positiveInfinity
        self.live = live
    }
}

/// Composed frames for the editor's canvas, read ahead of the player's clock.
///
/// ⚠️ **WHY THE PLAYER DOES NOT DRAW THEM ITSELF.** On the iOS 27 simulator an
/// `AVPlayerItem` carrying ANY video composition — the built-in compositor or a
/// custom one, configuration-built or mutable — fails to become ready the moment
/// something renders it: an `AVPlayerItemVideoOutput` (with or without pixel
/// attributes, added before or after it is ready), an `AVPlayerVideoOutput`, or
/// an `AVPlayerLayer`. Measured: `AVFoundationErrorDomain -11800`, underlying
/// `-12784` from `itemfig_rebuildRenderPipelinesAndBoss`, and the editor's
/// canvas froze for good on the first transition chosen. The same composition
/// reads perfectly through `AVAssetReaderVideoCompositionOutput`, exports, and
/// feeds an image generator.
///
/// So the item plays the arrangement WITHOUT a composition — its sound and its
/// clock — and this reads the composed pictures from the same arrangement,
/// through the same `VideoCompositor` the export uses, a few frames ahead of
/// wherever that clock says the item is.
///
/// ⚠️ **A SEEK, A LOOP OR A SCRUB RESTARTS THE READER.** A reader cannot seek:
/// it is made for a time range and only goes forward. Any request outside what
/// has been read makes a new one, starting at the requested time — and so does
/// a redraw of a paused moment (`refresh`).
final class ComposedFrameReader: @unchecked Sendable {
    // ⚠️ `@unchecked`: every mutable property is guarded by `state`'s lock, and
    // the reader objects are only ever touched on `queue`.

    private let video: ComposedVideo
    private let queue = DispatchQueue(label: "ComposedFrameReader", qos: .userInitiated)

    private struct State {
        /// Frames read and not yet passed, oldest first.
        var frames: [(time: CMTime, buffer: CVPixelBuffer)] = []
        /// The newest time anyone asked for.
        var wanted: CMTime = .invalid
        /// Bumped for every restart; a reader whose generation is stale stops.
        var generation = 0
        /// Where the running reader started, and whether it has run out.
        var startedAt: CMTime = .invalid
        var exhausted = false
        var reading = false
        /// Whether this reader has been shut down for good.
        var closed = false
        /// The time of the frame last handed out, so a frame is handed once.
        var handedOut: CMTime = .invalid
        /// When the running reader was started, for the restart throttle.
        var restartedAtHost: CFTimeInterval = 0
        /// When `wanted` was asked, to tell playback from a jump.
        var wantedAtHost: CFTimeInterval = 0
        /// Whether the running reader has produced anything yet.
        var producedAny = false
        /// What the last start cost: from the restart to its first frame. The
        /// lead a catch-up restart aims ahead by — see `catchUpStart`.
        var lastStartCost: CFTimeInterval = 0
        /// A restart decided but held back by the throttle.
        var restartOwed = false
        /// Whether that restart is a catch-up — one that must land ahead of the
        /// clock rather than on it.
        var restartAhead = false
        /// When the running reader failed — a reader that could not start or
        /// broke off is tried again after `retryAfter`.
        var failedAt: CFTimeInterval?
        #if DEBUG
        /// Test hook: how many starts to fail as a reader that cannot start.
        var failingStarts = 0
        #endif
        /// The moment `refresh` asked to draw again, until a reader is started
        /// for it — or until the clock moves on. Invalid when none is owed.
        var redrawAt: CMTime = .invalid
        /// Whether the running reader's frame for `redrawAt` has been handed out
        /// since the redraw was asked.
        var shownBeforeRedraw = false
    }

    private let state = OSAllocatedUnfairLock(uncheckedState: State())
    private let wake = DispatchSemaphore(value: 0)

    /// How many frames may wait ahead of the clock.
    static let lookahead = 6

    init(_ video: ComposedVideo) {
        self.video = video
    }

    deinit {
        close()
    }

    /// Stops reading for good.
    func close() {
        state.withLockUnchecked {
            $0.closed = true
            $0.generation += 1
            $0.frames.removeAll()
        }
        wake.signal()
    }

    /// The frame to show at `time`, if a new one is ready: the newest frame at or
    /// before it that has not been handed out yet.
    ///
    /// ⚠️ **NEVER WAITS.** This runs on the display link; a request the reader
    /// cannot answer yet returns nil and the surface keeps its picture.
    func frame(at time: CMTime) -> (buffer: CVPixelBuffer, time: CMTime)? {
        guard time.isValid, time >= .zero else { return nil }
        let now = CACurrentMediaTime()
        var restart = false
        let answer: (buffer: CVPixelBuffer, time: CMTime)? = state.withLockUnchecked { state in
            guard !state.closed else { return nil }
            if Self.jumped(state, to: time, at: now) {
                state.restartOwed = true
                state.restartAhead = false
            } else if Self.fellBehind(state, at: time) {
                state.restartOwed = true
                state.restartAhead = true
            }
            // ⚠️ **A FAILED READER IS TRIED AGAIN.** Left alone, a reader that
            // could not start marked itself done, and a paused canvas stayed
            // blank until the next seek — which, on a paused clip, may never come.
            if let failed = state.failedAt, now - failed > Self.retryAfter {
                state.failedAt = nil
                state.restartOwed = true
            }
            state.wanted = time
            state.wantedAtHost = now
            // ⚠️ A REDRAW IS FOR A CLOCK THAT STANDS STILL — see `refresh`.
            if state.redrawAt.isValid, state.redrawAt != time {
                state.redrawAt = .invalid
            }
            if state.restartOwed {
                // ⚠️ THROTTLED WHILE A FRESH READER HAS NOT ANSWERED YET. A scrub
                // asks for a new moment every frame, and a reader cancelled
                // every frame never produces one; the owed restart is kept and
                // made on a later beat, at wherever the finger has got to.
                guard !state.reading || state.producedAny
                        || now - state.restartedAtHost > Self.restartThrottle
                else { return nil }
                Self.restart(
                    &state,
                    at: state.restartAhead
                        ? Self.catchUpStart(for: time, lastStartCost: state.lastStartCost)
                        : time,
                    now: now
                )
                restart = true
                return nil
            }
            if state.redrawAt.isValid {
                // ⚠️ WHAT THE RUNNING READER HAS FOR THIS MOMENT IS SHOWN FIRST,
                // AND A READER THAT HAS NOT ANSWERED IS NEVER CANCELLED — the
                // moment is the same, so its answer is still worth having.
                if !state.shownBeforeRedraw, let frame = Self.handOut(&state, at: time) {
                    state.shownBeforeRedraw = true
                    return frame
                }
                guard !state.reading || state.producedAny else { return nil }
                Self.restart(&state, at: time, now: now)
                restart = true
                return nil
            }
            return Self.handOut(&state, at: time)
        }
        if restart {
            startReading()
        } else {
            wake.signal()
        }
        return answer
    }

    /// Draws the moment last asked for again, through a fresh reader — so a
    /// change the compositor reads on every frame, the live look, reaches a
    /// canvas that is standing still.
    ///
    /// ⚠️ **ONLY WHILE THE CLOCK STANDS STILL.** A playing clip's next frames are
    /// composed after the change and wear it; restarting under it would cost a
    /// decode from the keyframe on every tick of a slider, and the picture would
    /// stutter for as long as the finger moved. The frames already read ahead
    /// (at most `lookahead`) are still shown, so a playing change lands a few
    /// frames late. A request for any other moment than the last one asked drops
    /// the redraw.
    ///
    /// ⚠️ **COALESCED: AT MOST ONE READER ON ITS WAY FOR IT.** A slider asks
    /// sixty times a second, and a fresh reader answers only after a decode from
    /// the keyframe. The redraw is made on a later request — once the running
    /// reader has shown what it has for this moment — so the canvas follows the
    /// finger at the pace a reader can go, and the last change always gets a
    /// reader started after it.
    func refresh() {
        state.withLockUnchecked { state in
            guard !state.closed, state.wanted.isValid else { return }
            state.redrawAt = state.wanted
            state.shownBeforeRedraw = false
        }
        wake.signal()
    }

    /// The newest frame at or before `time` that has not been handed out, and
    /// every older one dropped.
    private static func handOut(
        _ state: inout State, at time: CMTime
    ) -> (buffer: CVPixelBuffer, time: CMTime)? {
        guard let index = state.frames.lastIndex(where: { $0.time <= time }) else { return nil }
        let chosen = state.frames[index]
        state.frames.removeFirst(index)
        guard chosen.time != state.handedOut else { return nil }
        state.handedOut = chosen.time
        return (buffer: chosen.buffer, time: chosen.time)
    }

    /// Where a reader given up for falling behind should start.
    ///
    /// ⚠️ **AHEAD OF THE CLOCK, BY WHAT THE LAST START COST.** Started where the
    /// clock stands, a fresh reader has to decode from the keyframe before it —
    /// measured at 0.4 to 1.5s — and by the time its first frame exists the
    /// clock has moved that far on, so it is behind again and gives up again.
    /// Measured on a loaded machine: thirty-one restarts and a lag that reached
    /// 9.1s, with the picture frozen throughout. Aiming at where the clock WILL
    /// be lands the first frame in front of it instead. The film between is
    /// skipped — which is what a player that cannot keep up must do, and it is
    /// what freezing was hiding.
    ///
    /// ⚠️ **NEVER MORE THAN A SECOND**, or a single slow start would throw away
    /// film the machine could have caught up with; and never less than the
    /// throttle, so the lead is a lead.
    static func catchUpStart(for time: CMTime, lastStartCost: CFTimeInterval) -> CMTime {
        let lead = min(max(lastStartCost, restartThrottle), 1.0)
        return time + CMTime(seconds: lead, preferredTimescale: 600)
    }

    /// Everything read so far dropped, and a new reader due at `time`.
    private static func restart(_ state: inout State, at time: CMTime, now: CFTimeInterval) {
        state.restartOwed = false
        state.restartAhead = false
        state.redrawAt = .invalid
        state.generation += 1
        state.frames.removeAll()
        state.startedAt = time
        state.exhausted = false
        state.reading = true
        state.producedAny = false
        state.handedOut = .invalid
        state.restartedAtHost = now
        state.failedAt = nil
    }

    /// How long after a failure a reader is tried again.
    static let retryAfter: CFTimeInterval = 0.5

    /// How long a fresh reader is given to answer before a newer request
    /// replaces it.
    static let restartThrottle: CFTimeInterval = 0.08

    /// How far behind the clock a reader that IS producing may fall before it
    /// is given up and started again where the clock is.
    static let giveUpBehind: Double = 2.0

    /// Whether the clock moved in a way playback cannot explain: backwards, or
    /// forwards faster than twice real time. A seek, a wrap, a scrub.
    ///
    /// ⚠️ **NOT "PAST WHAT HAS BEEN READ".** A reader's first frame waits for a
    /// decode from the keyframe before its start — measured at 0.4 to 1.5s on
    /// the simulator for a file keyed every 8s — and a clock that simply ran on
    /// meanwhile is not a reason to start again: restarted every 0.35s, the
    /// reader never produced a frame at all and the canvas froze. Decoding on
    /// from there is faster than real time, and it catches up by itself.
    private static func jumped(_ state: State, to time: CMTime, at now: CFTimeInterval) -> Bool {
        guard state.startedAt.isValid, state.wanted.isValid else { return true }
        let moved = (time - state.wanted).seconds
        let elapsed = max(now - state.wantedAtHost, 0)
        return moved < -1.0 / 600 || moved > elapsed * 2 + 0.1
    }

    /// Whether a reader that has been producing frames is not keeping up.
    private static func fellBehind(_ state: State, at time: CMTime) -> Bool {
        guard state.producedAny, !state.exhausted, let latest = state.frames.last?.time else {
            return false
        }
        return (time - latest).seconds > giveUpBehind
    }

    /// ⚠️ **A PROBE, RESOLVED ONCE.** Under `-composed-probe` every restart and
    /// every failure is printed with the time it was asked for — "the canvas
    /// froze" has several causes, and the restart pattern tells them apart.
    static let probes = ProcessInfo.processInfo.arguments.contains("-composed-probe")

    private func startReading() {
        let generation = state.withLockUnchecked { $0.generation }
        let start = state.withLockUnchecked { $0.startedAt }
        if Self.probes {
            let frames = state.withLockUnchecked { $0.frames.count }
            print(String(format: "[composed] restart at=%.3f generation=%d dropped=%d", start.seconds, generation, frames))
        }
        let video = video
        wake.signal()
        queue.async { [weak self] in
            self?.read(generation: generation, from: start, video: video)
        }
    }

    private func read(generation: Int, from start: CMTime, video: ComposedVideo) {
        func current() -> Bool { state.withLockUnchecked { $0.generation == generation && !$0.closed } }
        if Self.probes { print("[composed] read enter generation=\(generation) current=\(current())") }
        guard current() else { return }
        // ⚠️ **PAST THE END IS NOT A FAILURE.** A reader asked to start after
        // the last picture reads nothing; retried, it would spin for ever.
        let pastTheEnd = video.end.isValid && start >= video.end - CMTime(value: 1, timescale: 600)
        func failed() {
            let now = CACurrentMediaTime()
            state.withLockUnchecked {
                guard $0.generation == generation else { return }
                $0.reading = false
                if pastTheEnd {
                    $0.exhausted = true
                } else {
                    $0.failedAt = now
                }
            }
        }
        #if DEBUG
        let failing = state.withLockUnchecked { state -> Bool in
            guard state.failingStarts > 0 else { return false }
            state.failingStarts -= 1
            return true
        }
        if failing { return failed() }
        #endif
        guard let reader = try? AVAssetReader(asset: video.asset) else { return failed() }
        let output = AVAssetReaderVideoCompositionOutput(videoTracks: video.tracks, videoSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: String]()
        ])
        output.videoComposition = video.composition
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { return failed() }
        reader.add(output)
        reader.timeRange = CMTimeRange(start: start, duration: .positiveInfinity)
        guard reader.startReading() else {
            Self.trace("composed reader failed to start: \(String(describing: reader.error))")
            if Self.probes { print("[composed] failed to start: \(String(describing: reader.error))") }
            return failed()
        }
        defer { reader.cancelReading() }
        if Self.probes { print("[composed] reading generation=\(generation) status=\(reader.status.rawValue)") }
        var produced = 0
        var windowFrames = 0
        var windowStart = CACurrentMediaTime()
        while current() {
            let full = state.withLockUnchecked { state -> Bool in
                guard state.frames.count >= Self.lookahead, let last = state.frames.last else { return false }
                // Enough read, unless the clock has run past all of it.
                return !state.wanted.isValid || last.time > state.wanted
            }
            if full {
                _ = wake.wait(timeout: .now() + .milliseconds(100))
                continue
            }
            guard let sample = output.copyNextSampleBuffer() else {
                if reader.status == .failed {
                    Self.trace("composed reader failed: \(String(describing: reader.error))")
                    failed()
                } else {
                    state.withLockUnchecked { if $0.generation == generation { $0.exhausted = true; $0.reading = false } }
                }
                if Self.probes {
                    print(String(format: "[composed] ended status=%d from=%.3f error=%@",
                                 reader.status.rawValue, start.seconds, String(describing: reader.error)))
                }
                return
            }
            produced += 1
            if Self.probes {
                windowFrames += 1
                let now = CACurrentMediaTime()
                if now - windowStart >= 1 {
                    let lag = state.withLockUnchecked { ($0.wanted - CMSampleBufferGetPresentationTimeStamp(sample)).seconds }
                    print(String(format: "[composed] %d frames/s lag=%.3fs", windowFrames, lag))
                    windowFrames = 0
                    windowStart = now
                }
            }
            if Self.probes, produced == 1 {
                print(String(format: "[composed] first frame generation=%d at=%.3f", generation,
                             CMSampleBufferGetPresentationTimeStamp(sample).seconds))
            }
            guard let buffer = CMSampleBufferGetImageBuffer(sample) else { continue }
            let time = CMSampleBufferGetPresentationTimeStamp(sample)
            state.withLockUnchecked { state in
                guard state.generation == generation else { return }
                if !state.producedAny {
                    // What this start cost, for the next catch-up's lead.
                    state.lastStartCost = max(CACurrentMediaTime() - state.restartedAtHost, 0)
                }
                state.frames.append((time: time, buffer: buffer))
                state.producedAny = true
            }
        }
    }

    private static func trace(_ message: String) {
        Task { @MainActor in VideoPlaybackTrace.emit(message) }
    }

    #if DEBUG
    /// Test hook: makes the next `count` readers fail to start.
    func debugFailNextStarts(_ count: Int) {
        state.withLockUnchecked { $0.failingStarts = count }
    }

    /// How many frames are waiting, and whether a reader is running.
    var debugState: (frames: Int, reading: Bool, generation: Int) {
        state.withLockUnchecked { ($0.frames.count, $0.reading, $0.generation) }
    }

    /// Test hook: where the running reader was started, and what the last start
    /// cost.
    var debugStart: (at: CMTime, cost: CFTimeInterval) {
        state.withLockUnchecked { ($0.startedAt, $0.lastStartCost) }
    }

    /// Test hook: states what a start cost, so a catch-up's lead can be aimed
    /// without starving the machine to make one slow.
    func debugSetLastStartCost(_ seconds: CFTimeInterval) {
        state.withLockUnchecked { $0.lastStartCost = seconds }
    }
    #endif
}
