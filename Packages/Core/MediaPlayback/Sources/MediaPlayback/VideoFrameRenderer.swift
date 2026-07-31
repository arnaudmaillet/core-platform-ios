import AVFoundation
import CoreMedia
import CoreVideo
import QuartzCore

/// One decoder, N display surfaces.
///
/// This is the type the whole `AVSampleBufferDisplayLayer` pivot exists for.
/// Per tick it pulls **one** frame from its `VideoFrameSource` and hands that
/// same `CVPixelBuffer` to every attached surface, wrapped in a per-surface
/// `CMSampleBuffer`. No copy, no second decode, no clock to reconcile.
///
/// The consequence for the hero transition (#83): a grid tile and a full-screen
/// page can be attached at the same time, showing the same frame, and the
/// "handoff" between them is `addSurface` / `removeSurface` — bookkeeping that
/// draws nothing and blocks nothing. Phase 1 only ever runs one surface at a
/// time; the set is plural from the start so Phase 2 is a call-site change
/// rather than a rewrite.
///
/// ## Ownership rule, which is the memory design
///
/// The pixel buffers belong to `AVPlayerItemVideoOutput`'s pool. We borrow one,
/// wrap it, enqueue it, and forget it — this renderer holds **no** reference to
/// a frame between ticks. That is what "pixel buffer recycling" means in this
/// topology: not a pool of our own (which would add a copy per frame to buffers
/// AVFoundation already recycles), but the discipline of never being the reason
/// one cannot return to the pool. A retained frame is a frame the decoder must
/// allocate around, and at six concurrent outputs that is how this design runs
/// out of memory.
@MainActor
final class VideoFrameRenderer {
    private let source: VideoFrameSource

    /// Weak, and plural. Weak because a surface's owner (a recycled grid cell)
    /// may drop it without telling us; plural because that is the point.
    private let surfaces = NSHashTable<VideoRenderView>.weakObjects()

    /// Rebuilt only when the buffer stops matching it.
    /// `CMVideoFormatDescriptionCreateForImageBuffer` is not free, and at 30fps
    /// x 6 tiles a per-frame rebuild is pure waste — but it cannot simply be
    /// built once either: an ABR rung switch changes the decoded dimensions
    /// mid-playback, and this codebase switches rungs deliberately (a tile
    /// capped to `tileBitRateCap` going full screen uncapped).
    private var formatDescription: CMVideoFormatDescription?

    private var isRegistered = false

    /// Frames dispatched since this renderer was created. Not a debug counter —
    /// see `VideoRenderView.enqueuedFrameCount` for why liveness has to be
    /// counted rather than inferred.
    private(set) var dispatchedFrameCount = 0

    private var lastRateSampleHostTime: CFTimeInterval = 0
    private var framesSinceRateSample = 0

    /// Gap tracking, which is how a loop wrap is judged.
    ///
    /// The wrap is observable without asking anyone: `AVPlayerItemDidPlayToEndTime`
    /// seeks to zero, so the next frame's item time is EARLIER than the last
    /// one's. That backwards jump is the wrap, and the host-time distance
    /// across it is exactly "how long was this surface without a new frame" —
    /// the only number that decides whether the loop needs a flush.
    private var lastItemTime: CMTime = .invalid
    private var lastDispatchHostTime: CFTimeInterval = 0
    private var maxGapSinceRateSample: CFTimeInterval = 0

    init(player: AVPlayer) {
        self.source = VideoFrameSource(player: player)
    }

    var player: AVPlayer { source.player }

    // MARK: - Item lifecycle

    func setItem(_ item: AVPlayerItem?) {
        source.setItem(item)
        // A new item's first frame has nothing to do with the old item's, and
        // every attached surface is currently showing the latter.
        formatDescription = nil
        lastItemTime = .invalid
        lastDispatchHostTime = 0
        updateClockRegistration()
    }

    // MARK: - Surfaces

    func addSurface(_ surface: VideoRenderView) {
        guard !surfaces.contains(surface) else { return }
        surfaces.add(surface)
        updateClockRegistration()
        log("surface + (\(surfaces.count) attached)")
    }

    func removeSurface(_ surface: VideoRenderView) {
        guard surfaces.contains(surface) else { return }
        surfaces.remove(surface)
        updateClockRegistration()
        log("surface - (\(surfaces.count) attached)")
    }

    var surfaceCount: Int { surfaces.count }

    /// Stops this renderer for good: no clock, no output, no surfaces. Called
    /// when its player goes back to the idle pool.
    func invalidate() {
        for surface in surfaces.allObjects { surface.detachFromRenderer() }
        surfaces.removeAllObjects()
        source.setItem(nil)
        updateClockRegistration()
    }

    /// Registered only while there is both something to pull and somewhere to
    /// put it. A pooled player sitting idle between items must not keep the
    /// app-wide display link alive.
    private func updateClockRegistration() {
        let wants = source.hasItem && surfaces.count > 0
        guard wants != isRegistered else { return }
        isRegistered = wants
        if wants {
            VideoFrameClock.shared.add(self)
        } else {
            VideoFrameClock.shared.remove(self)
        }
    }

    // MARK: - The tick

    func render(atHostTime hostTime: CFTimeInterval) {
        let targets = surfaces.allObjects
        guard !targets.isEmpty else { return }
        // Sampled BEFORE the "no new frame" return, deliberately. A renderer
        // that has stalled takes that return every tick, so a rate logged after
        // it would simply never print — and a probe that goes quiet when the
        // thing it watches breaks is the exact failure #83 has been caught by
        // twice. Stalled means `fps=0` on the line, not the absence of a line.
        sampleFrameRate(atHostTime: hostTime)
        guard let frame = source.copyFrame(atHostTime: hostTime) else { return }
        noteDispatch(itemTime: frame.itemTime, hostTime: hostTime)
        guard let format = formatDescription(matching: frame.buffer) else { return }

        for surface in targets {
            // Built per surface rather than once and shared. The wrapper is a
            // few hundred bytes around a retained buffer, so N of them is
            // cheap; what it buys is that each display layer gets a sample
            // buffer nothing else holds, and no question about two renderers
            // racing on one buffer's attachments.
            guard let sample = Self.makeSampleBuffer(
                imageBuffer: frame.buffer,
                format: format,
                presentationTime: frame.itemTime
            ) else { continue }
            surface.enqueue(sample)
        }
        dispatchedFrameCount += 1
        framesSinceRateSample += 1
    }

    /// Records the inter-frame gap, and reports it when the item time jumps
    /// backwards — i.e. when the clip has looped.
    private func noteDispatch(itemTime: CMTime, hostTime: CFTimeInterval) {
        let gap = lastDispatchHostTime == 0 ? 0 : hostTime - lastDispatchHostTime
        maxGapSinceRateSample = max(maxGapSinceRateSample, gap)
        if VideoRenderFlags.logsFrameDispatch,
           lastItemTime.isValid, itemTime < lastItemTime {
            log(String(format: "WRAP %.3fs -> %.3fs gap=%.1fms",
                       lastItemTime.seconds, itemTime.seconds, gap * 1000))
        }
        lastItemTime = itemTime
        lastDispatchHostTime = hostTime
    }

    /// Per-second dispatch rate under `-avsbdl-log`.
    ///
    /// This is the liveness signal the acceptance harness has been missing.
    /// `isReadyForDisplay` cannot distinguish a live surface from one holding a
    /// frozen frame — it reports true for both — so criterion 1's `dips` gate
    /// can pass over a surface the viewer watched freeze. A frame rate cannot
    /// lie that way: frames either arrived or they did not.
    private func sampleFrameRate(atHostTime hostTime: CFTimeInterval) {
        guard VideoRenderFlags.logsFrameDispatch else { return }
        if lastRateSampleHostTime == 0 {
            lastRateSampleHostTime = hostTime
            return
        }
        let elapsed = hostTime - lastRateSampleHostTime
        guard elapsed >= 1 else { return }
        log(String(format: "fps=%.1f maxGap=%.1fms surfaces=%d total=%d",
                   Double(framesSinceRateSample) / elapsed, maxGapSinceRateSample * 1000,
                   surfaces.count, dispatchedFrameCount))
        lastRateSampleHostTime = hostTime
        framesSinceRateSample = 0
        maxGapSinceRateSample = 0
    }

    private func formatDescription(matching buffer: CVPixelBuffer) -> CMVideoFormatDescription? {
        if let formatDescription,
           CMVideoFormatDescriptionMatchesImageBuffer(formatDescription, imageBuffer: buffer) {
            return formatDescription
        }
        var created: CMVideoFormatDescription?
        let status = CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: buffer,
            formatDescriptionOut: &created
        )
        guard status == noErr else {
            log("format description failed: \(status)")
            return nil
        }
        formatDescription = created
        return created
    }

    private static func makeSampleBuffer(
        imageBuffer: CVPixelBuffer,
        format: CMVideoFormatDescription,
        presentationTime: CMTime
    ) -> CMSampleBuffer? {
        // The item time goes in as the PTS because it is true and costs
        // nothing, but nothing schedules against it: the layer runs with no
        // control timebase, and every sample carries `DisplayImmediately`. That
        // is deliberate. Timed mode would mean running a second timebase beside
        // the player's and keeping the two in agreement — reintroducing exactly
        // the clock-reconciliation bug class this pivot was warned about. Here
        // the pacing lives in ONE place: the pull is already scheduled off the
        // player's own timebase, so a frame that arrives has by construction
        // arrived at the right moment, and the layer's only job is to show it.
        var timing = CMSampleTimingInfo(
            duration: .invalid,
            presentationTimeStamp: presentationTime,
            decodeTimeStamp: .invalid
        )
        var sampleBuffer: CMSampleBuffer?
        let status = CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: imageBuffer,
            formatDescription: format,
            sampleTiming: &timing,
            sampleBufferOut: &sampleBuffer
        )
        guard status == noErr, let sampleBuffer else { return nil }

        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: true),
           CFArrayGetCount(attachments) > 0 {
            let raw = CFArrayGetValueAtIndex(attachments, 0)
            let dictionary = unsafeBitCast(raw, to: CFMutableDictionary.self)
            CFDictionarySetValue(
                dictionary,
                Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                Unmanaged.passUnretained(kCFBooleanTrue).toOpaque()
            )
        }
        return sampleBuffer
    }

    #if DEBUG
    /// Whether this renderer is currently being ticked. Asserted per-renderer
    /// rather than by counting the clock's subscribers, because the test bundle
    /// runs suites in parallel and under `AVSBDL_RENDER=1` the controller suite
    /// registers renderers of its own — a global count is a race, this is not.
    var debugIsRegisteredWithClock: Bool { isRegistered }
    #endif

    private func log(_ message: @autoclosure () -> String) {
        guard VideoRenderFlags.logsFrameDispatch else { return }
        print(String(format: "[avsbdl] %.3f renderer %@", CACurrentMediaTime(), message()))
    }
}
