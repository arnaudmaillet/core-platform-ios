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
        guard output.hasNewPixelBuffer(forItemTime: itemTime) else { return nil }
        guard let buffer = output.copyPixelBuffer(forItemTime: itemTime, itemTimeForDisplay: nil) else {
            return nil
        }
        Self.ensureColorAttachments(on: buffer)
        return (buffer, itemTime)
    }

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
