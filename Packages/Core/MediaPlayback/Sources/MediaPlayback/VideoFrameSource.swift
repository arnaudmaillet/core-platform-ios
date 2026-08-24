import AVFoundation
import CoreMedia
import CoreVideo

/// One `AVPlayer`'s decoded video, exposed as pixel buffers we can pull.
///
/// The player keeps everything it is good at — the ABR ladder,
/// `preferredPeakBitRate`, the playhead, and (from Phase 3) audio output. What
/// it stops doing is owning a display surface. An `AVPlayerItemVideoOutput`
/// taps the same decode that would have fed an `AVPlayerLayer`, and hands us
/// the frame instead.
///
/// **Why this makes the hero handoff disappear.** An `AVPlayer` renders into
/// exactly one `AVPlayerLayer`, and moving that binding costs a decode
/// round-trip during which neither layer draws (measured: 65–99ms, see #83). A
/// pixel buffer has no such exclusivity — it can be wrapped and enqueued into
/// as many layers as we like. There is no binding to move, so there is no
/// window.
@MainActor
final class VideoFrameSource {
    let player: AVPlayer

    private var output: AVPlayerItemVideoOutput?
    private weak var observedItem: AVPlayerItem?

    init(player: AVPlayer) {
        self.player = player
    }

    /// Points the output at `item`, or tears it down for `nil`.
    ///
    /// The output is a property of the *item*, not the player, so it has to be
    /// re-installed every time the controller replaces one. Called from
    /// `VideoPlaybackController` alongside `replaceCurrentItem`.
    func setItem(_ item: AVPlayerItem?) {
        if let observedItem, let output {
            observedItem.remove(output)
        }
        output = nil
        observedItem = nil
        guard let item else { return }

        // `outputSettings: nil` asks for the decoder's native format, which is
        // the whole point: any explicit pixel-format request inserts a
        // conversion between the decoder and us, costing a copy per frame and
        // flattening HDR to whatever we named. Decoded buffers are already
        // IOSurface-backed, which is what `AVSampleBufferDisplayLayer` needs,
        // and the colour attachments (primaries, transfer function, YCbCr
        // matrix) ride along on the buffer — so asking for nothing is both the
        // cheapest and the most correct request.
        let output = AVPlayerItemVideoOutput(outputSettings: nil)
        // We render the frames ourselves; without this the player also decodes
        // for a layer that does not exist.
        output.suppressesPlayerRendering = true
        item.add(output)
        self.output = output
        self.observedItem = item
    }

    /// The frame that should be on screen at `hostTime`, or `nil` when the
    /// output has nothing new — which is the common case, since content runs at
    /// ~30fps and we ask up to 120 times a second.
    ///
    /// Returns the item time alongside the buffer so the renderer can stamp it
    /// as the presentation timestamp. Ownership: the buffer belongs to the
    /// output's pool and is only borrowed. Wrap it, enqueue it, drop it — see
    /// `VideoFrameRenderer` for why holding one is the memory bug in this
    /// design.
    func copyFrame(atHostTime hostTime: CFTimeInterval) -> (buffer: CVPixelBuffer, itemTime: CMTime)? {
        guard let output else { return nil }
        let itemTime = output.itemTime(forHostTime: hostTime)
        // `itemTime(forHostTime:)` reads the PLAYER's timebase — the same clock
        // its audio renderer runs on. That is the entire A/V sync answer for
        // Phase 3, and it is free: we never invent a clock, we only ask the
        // player what time it is.
        //
        // Before playback starts the timebase has no rate and the answer comes
        // back invalid or negative; both mean "nothing to show yet".
        guard itemTime.isValid, itemTime >= .zero else { return nil }
        // ⚠️ THE OUTPUT'S CLOCK CAN FALL BEHIND THE PLAYER'S, AND IT DOES.
        //
        // Measured on a paused-then-resumed adaptive stream: `out=10.500s` while
        // `player=21.231s` — the output ten and a half seconds behind, which is
        // exactly how long the clip had been held. Asking it for the frame at
        // 10.5s while playback is really at 21.2s makes it deliver its backlog
        // as fast as the display link asks, and THAT is the reported
        // fast-forward. The viewer's own words for it were "as if it were trying
        // to catch up on a delay"; it was, and the delay was ten seconds.
        //
        // The player's position is the truth about where playback is, so a
        // disagreement is resolved in its favour. The threshold keeps this off
        // the normal path, where the two agree within a frame or two and
        // `itemTime(forHostTime:)` is the better answer — it is anchored to the
        // upcoming refresh rather than to now.
        let playerTime = player.currentTime()
        var wantedTime = itemTime
        if playerTime.isValid, abs((playerTime - itemTime).seconds) > 0.5 {
            wantedTime = playerTime
            VideoPlaybackTrace.emit(String(
                format: "resynced output=%.3fs player=%.3fs",
                itemTime.seconds, playerTime.seconds
            ))
        }
        guard output.hasNewPixelBuffer(forItemTime: wantedTime) else {
            // ⚠️ Nothing new is not a catch-up, and saying otherwise leaves a
            // spinner turning over a clip that has simply been paused. A drain
            // always HAS frames waiting — that is what makes it a drain — so
            // reaching here means the wait, whatever it was, is over.
            isCatchingUp = false
            return nil
        }
        // ⚠️ THE BUFFER'S OWN TIME, not the clock's.
        //
        // These are not the same number and the difference is a whole
        // investigation. `itemTime(forHostTime:)` is the player's TIMEBASE — at
        // rate 1 it advances at exactly 1x by construction, so a probe built on
        // it can only ever report that the clock is on time. It reported that
        // for four runs while the viewer was plainly watching the picture race.
        //
        // What the eye sees is which FRAME is on screen, and that is this: the
        // presentation time of the buffer the output actually handed back.
        // When the two disagree, the pictures are running away from the clock —
        // which is the only shape left that fits "fast for a few seconds, then
        // normal" with a playhead measured at 1x throughout.
        var displayTime = CMTime.invalid
        guard let buffer = output.copyPixelBuffer(
            forItemTime: wantedTime, itemTimeForDisplay: &displayTime
        ) else {
            return nil
        }
        // ⚠️ A FRAME FROM THE PAST IS DROPPED, NOT SHOWN.
        //
        // This is the reported fast-forward, finally located. The output's clock
        // agrees with the player — that was measured and is why re-requesting a
        // different time changed nothing — but its queue of DECODED frames can
        // be seconds behind, and `copyPixelBuffer` serves the oldest it has
        // rather than refusing. Asked for the frame at 18.5s it returns the one
        // from 15.6s, and the next tick 15.75s, and so on: an entire backlog
        // delivered one frame per display refresh, which on screen is the
        // picture racing until it catches up. Measured across one burst, the gap
        // closing 2.90 → 2.75 → 2.56 → … → 0.24 while the player advanced
        // normally throughout.
        //
        // The copy above already consumed the frame, so dropping it here is what
        // drains the queue: the surface holds its last picture for the fraction
        // of a second that takes, then resumes at the place playback is actually
        // at. A cut, rather than a scrub through everything that was missed.
        //
        // ⚠️ AND BOUNDED, because a guard that drops frames must not be able to
        // freeze the picture. If the output is steadily behind rather than
        // draining a backlog, dropping every frame would show nothing at all —
        // a worse fault than the one being fixed, and one that would look like
        // the player dying. After `maxConsecutiveDrops` the next frame is shown
        // whatever its age: late video beats no video.
        let behind = displayTime.isValid
            ? (wantedTime - displayTime).seconds : 0
        if behind > Self.staleFrameTolerance {
            // ⚠️ THE QUESTION IS WHETHER THE GAP IS CLOSING, not how many frames
            // have been dropped.
            //
            // This was a fixed cap of 24, and the cap is what the viewer saw:
            // after a fifth of a second it started letting stale frames through
            // again, so a long backlog came out as a fast, stuttering scramble
            // instead of a wait — "it advances very fast, stuttering, to get the
            // cursor back". Dropping is right; stopping early is what made it
            // ugly.
            //
            // A closing gap resolves itself, however long it takes, so it is
            // waited out. A gap that stops closing never will, and then a late
            // picture beats none — that is the case the old cap existed for, and
            // it is the only one it should ever have covered.
            let closing = !lastBehind.isFinite || behind < lastBehind - 0.001
            lastBehind = behind
            if closing || stalledDrops < Self.maxStalledDrops {
                stalledDrops = closing ? 0 : stalledDrops + 1
                isCatchingUp = true
                return nil
            }
            VideoPlaybackTrace.emit(String(
                format: "gave up catching up behind=%.3fs", behind
            ))
        }
        isCatchingUp = false
        stalledDrops = 0
        lastBehind = .infinity
        Self.ensureColorAttachments(on: buffer)
        lastClockTime = wantedTime
        return (buffer, displayTime.isValid ? displayTime : itemTime)
    }

    /// How far behind the requested time a frame may be and still be shown.
    ///
    /// Generous on purpose. Normal delivery is within a frame or two, and the
    /// fault this guards against is measured in SECONDS — so half a second
    /// separates them with room to spare, and no ordinary frame is ever at risk
    /// of being dropped for being slightly late.
    private static let staleFrameTolerance: Double = 0.5

    /// How many frames the gap may fail to close before the wait is abandoned.
    ///
    /// The safety valve, and only that: an output that is permanently behind
    /// rather than draining would otherwise never show anything again. Half a
    /// second at 120Hz, which no real catch-up spends standing still.
    private static let maxStalledDrops = 60
    private var stalledDrops = 0
    private var lastBehind: Double = .infinity

    /// Whether the picture is waiting for playback to catch up to it.
    ///
    /// Read by the renderer so the surface can say so. The honest state during
    /// a drain is "the frame you are looking at is old and the next one is not
    /// ready" — which is a load, and looks like one.
    private(set) var isCatchingUp = false

    /// The clock reading that went with the last frame handed out.
    ///
    /// ⚠️ Kept so the two can be compared. The frames racing while the clock
    /// keeps time and the clock itself running fast look identical from the
    /// screen, and they are different faults: one is the output handing back
    /// buffers ahead of what was asked for, the other is the timebase. Only
    /// logging both in one line tells them apart.
    private(set) var lastClockTime: CMTime = .invalid

    /// Gives a buffer default Rec. 709 colour attachments when it carries none.
    ///
    /// **This is the difference between video and a black rectangle**, and it
    /// cost a full investigation to find. `AVSampleBufferDisplayLayer` will not
    /// display a buffer whose colour space it cannot determine: the enqueue
    /// succeeds, the renderer's status stays healthy, the frame counter goes up,
    /// and the layer shows black. `AVPlayerLayer` tolerates the same buffer and
    /// renders it, which is why this appeared as an AVSBDL-only regression.
    ///
    /// Found by A/B: assets with proper metadata (the `-rich-media` HLS ladder)
    /// rendered, while the mock `PlaceholderVideoFetcher` clips — written by
    /// `AVAssetWriter` with no colour properties — came back black on every
    /// tile. Real content can be just as under-specified, so this belongs in
    /// the engine rather than in the fixtures.
    ///
    /// Rec. 709 is the right default for the SDR H.264 this decodes; a buffer
    /// that already declares its colour is left completely alone, so nothing
    /// correctly tagged is ever overridden.
    private static func ensureColorAttachments(on buffer: CVPixelBuffer) {
        guard CVBufferGetAttachment(buffer, kCVImageBufferYCbCrMatrixKey, nil) == nil else { return }
        CVBufferSetAttachment(buffer, kCVImageBufferYCbCrMatrixKey,
                              kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(buffer, kCVImageBufferColorPrimariesKey,
                              kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(buffer, kCVImageBufferTransferFunctionKey,
                              kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)
    }

    #if DEBUG
    /// The player's own account of why it is or is not producing frames.
    ///
    /// A renderer that dispatches nothing has `copyFrame` returning nil, and
    /// that has exactly two families of cause: the output has no new buffer
    /// because the PLAYER is not advancing (paused, or waiting on the network),
    /// or the item time is invalid. Printing the player's state alongside the
    /// item time separates them without another guess.
    var debugPlayerState: String {
        let control: String = switch player.timeControlStatus {
        case .paused: "PAUSED"
        case .waitingToPlayAtSpecifiedRate:
            "waiting(\(player.reasonForWaitingToPlay?.rawValue ?? "?"))"
        case .playing: "playing"
        @unknown default: "?"
        }
        guard let item = player.currentItem else { return "\(control) rate=\(player.rate) item=NIL" }
        let host = output.map { $0.itemTime(forHostTime: CACurrentMediaTime()) }
        return String(format: "%@ rate=%.2f time=%.2fs itemTime=%@ keepUp=%@ status=%@",
                      control, player.rate, item.currentTime().seconds,
                      host.map { $0.isValid ? String(format: "%.2fs", $0.seconds) : "INVALID" } ?? "no-output",
                      item.isPlaybackLikelyToKeepUp ? "Y" : "N",
                      item.status == .failed
                          ? "FAILED(\(item.error.map { String(describing: $0) } ?? "no error"))"
                          : (item.status == .readyToPlay ? "ready" : "unknown"))
    }
    #endif

    /// Whether there is an output installed at all — a player between items has
    /// nothing to pull and should not keep a renderer registered with the clock.
    var hasItem: Bool { output != nil }
}
