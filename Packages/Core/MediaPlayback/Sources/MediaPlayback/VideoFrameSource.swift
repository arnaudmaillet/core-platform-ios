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
        return (buffer, itemTime)
    }

    /// Whether there is an output installed at all — a player between items has
    /// nothing to pull and should not keep a renderer registered with the clock.
    var hasItem: Bool { output != nil }
}
