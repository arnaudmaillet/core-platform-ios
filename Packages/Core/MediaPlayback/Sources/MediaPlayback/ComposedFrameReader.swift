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

    init(asset: AVAsset, tracks: [AVAssetTrack], composition: AVVideoComposition) {
        self.asset = asset
        self.tracks = tracks
        self.composition = composition
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
/// has been read makes a new one, starting at the requested time.
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
        /// A restart decided but held back by the throttle.
        var restartOwed = false
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
            if Self.jumped(state, to: time, at: now) || Self.fellBehind(state, at: time) {
                state.restartOwed = true
            }
            state.wanted = time
            state.wantedAtHost = now
            if state.restartOwed {
                // ⚠️ THROTTLED WHILE A FRESH READER HAS NOT ANSWERED YET. A scrub
                // asks for a new moment every frame, and a reader cancelled
                // every frame never produces one; the owed restart is kept and
                // made on a later beat, at wherever the finger has got to.
                guard !state.reading || state.producedAny
                        || now - state.restartedAtHost > Self.restartThrottle
                else { return nil }
                state.restartOwed = false
                state.generation += 1
                state.frames.removeAll()
                state.startedAt = time
                state.exhausted = false
                state.reading = true
                state.producedAny = false
                state.handedOut = .invalid
                state.restartedAtHost = now
                restart = true
                return nil
            }
            guard let index = state.frames.lastIndex(where: { $0.time <= time }) else { return nil }
            let chosen = state.frames[index]
            state.frames.removeFirst(index)
            guard chosen.time != state.handedOut else { return nil }
            state.handedOut = chosen.time
            return (buffer: chosen.buffer, time: chosen.time)
        }
        if restart {
            startReading()
        } else {
            wake.signal()
        }
        return answer
    }

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
        guard let reader = try? AVAssetReader(asset: video.asset) else {
            state.withLockUnchecked { if $0.generation == generation { $0.exhausted = true; $0.reading = false } }
            return
        }
        let output = AVAssetReaderVideoCompositionOutput(videoTracks: video.tracks, videoSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: String]()
        ])
        output.videoComposition = video.composition
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { return }
        reader.add(output)
        reader.timeRange = CMTimeRange(start: start, duration: .positiveInfinity)
        guard reader.startReading() else {
            Self.trace("composed reader failed to start: \(String(describing: reader.error))")
            if Self.probes { print("[composed] failed to start: \(String(describing: reader.error))") }
            state.withLockUnchecked { if $0.generation == generation { $0.exhausted = true; $0.reading = false } }
            return
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
                state.withLockUnchecked { if $0.generation == generation { $0.exhausted = true; $0.reading = false } }
                if reader.status == .failed {
                    Self.trace("composed reader failed: \(String(describing: reader.error))")
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
                state.frames.append((time: time, buffer: buffer))
                state.producedAny = true
            }
        }
    }

    private static func trace(_ message: String) {
        Task { @MainActor in VideoPlaybackTrace.emit(message) }
    }

    #if DEBUG
    /// How many frames are waiting, and whether a reader is running.
    var debugState: (frames: Int, reading: Bool, generation: Int) {
        state.withLockUnchecked { ($0.frames.count, $0.reading, $0.generation) }
    }
    #endif
}
