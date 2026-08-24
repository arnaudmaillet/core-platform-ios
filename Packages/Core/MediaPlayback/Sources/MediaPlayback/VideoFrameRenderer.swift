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

    /// Surfaces that actually received the last frame — those in a window.
    /// Always <= `surfaceCount`; see the logging note in `sampleFrameRate`.
    private(set) var drawnSurfaceCount = 0

    private var hasVerifiedAttachment = false
    private var lastRateSampleHostTime: CFTimeInterval = 0
    private var framesSinceRateSample = 0

    /// Gap tracking, which is how a loop wrap is judged.
    ///
    /// The wrap is observable without asking anyone: `AVPlayerItemDidPlayToEndTime`
    /// seeks to zero, so the next frame's item time is EARLIER than the last
    /// one's. That backwards jump is the wrap, and the host-time distance
    /// across it is exactly "how long was this surface without a new frame" —
    /// the only number that decides whether the loop needs a flush.
    /// The most recent frame, kept solely to prime a joining surface. See
    /// `primeWithLastFrame` for why this one retention is allowed.
    private var lastFrame: (buffer: CVPixelBuffer, itemTime: CMTime)?

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
        // A new item's last frame is the OLD item's content; priming a joining
        // surface with it would show the wrong video.
        lastFrame = nil
        lastItemTime = .invalid
        lastDispatchHostTime = 0
        updateClockRegistration()
    }

    // MARK: - Surfaces

    func addSurface(_ surface: VideoRenderView) {
        guard !surfaces.contains(surface) else { return }
        surfaces.add(surface)
        primeWithLastFrame(surface)
        updateClockRegistration()
        log("surface + (\(surfaces.count) attached)")
    }

    /// Gives a joining surface the most recent frame immediately, instead of
    /// letting it wait for the next one.
    ///
    /// **Measured, and the reason this exists:** without it a flight card took
    /// 34-103ms (median ~44ms) to show its first frame, because dispatch is
    /// gated on `hasNewPixelBuffer` and at 24-30fps the next frame is up to
    /// 42ms away. That is the same order as the 65ms handoff window this whole
    /// pivot exists to remove — it would have shipped as "seamless" while
    /// actually flashing.
    ///
    /// Attaching genuinely costs the EXISTING surfaces nothing. It was the new
    /// surface that paid, and this is what makes the claim true for it too.
    ///
    /// This is a deliberate exception to the renderer's "hold no frame between
    /// ticks" rule: exactly ONE frame is retained, and one frame per renderer
    /// is bounded and small. The rule guards against unbounded retention
    /// starving the decoder's pool, which a single slot cannot do.
    private func primeWithLastFrame(_ surface: VideoRenderView) {
        // COLD PATH. `lastFrame` is nil until this renderer has dispatched at
        // least once, so on a cold flight — the first open of a tile whose
        // playback has only just started — there is nothing to prime with and
        // this silently does nothing. The joining surface then waits for the
        // next decode like it always did, which is why the flash is visible on
        // the first iteration and gone by the second: by then `lastFrame` is
        // populated and priming actually fires.
        //
        // Priming cannot manufacture a frame that does not exist yet. What the
        // caller must therefore do is not SHOW the surface until one arrives —
        // see `VideoRenderView.revealOnFirstFrame()`.
        guard let lastFrame, let format = formatDescription else {
            log("prime SKIPPED — no frame decoded yet (cold)")
            return
        }
        guard let sample = Self.makeSampleBuffer(
            imageBuffer: lastFrame.buffer,
            format: format,
            presentationTime: lastFrame.itemTime
        ) else { return }
        surface.enqueue(sample)
        log("prime ok")
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
        // Names what this is about to drop. `invalidate` was written when a
        // renderer served exactly ONE view; under N-surface it releases every
        // surface attached, which may include a flight card mid-flight and a
        // landing tile that has just taken ownership. A count above 1 here is
        // the bug, not a diagnostic curiosity.
        log("INVALIDATE dropping \(surfaces.count) surface(s): "
            + surfaces.allObjects.map { $0.debugLabelOrAnonymous }.sorted().joined(separator: ","))
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
        // Before the "no new frame" return, for the same reason as the line
        // above: a probe that goes quiet when its subject stalls is worthless.
        sampleDispatchRate(atHostTime: hostTime)
        guard let frame = source.copyFrame(atHostTime: hostTime) else { return }
        noteDispatch(itemTime: frame.itemTime, hostTime: hostTime)
        guard let format = formatDescription(matching: frame.buffer) else { return }

        lastFrame = frame
        var drawn = 0
        for surface in targets {
            // A surface outside the window hierarchy cannot be seen, and a
            // discarded flight card sits in exactly that state until ARC gets
            // to it. Skipping is enough — the set holds surfaces weakly, so it
            // empties itself; this only stops us paying for them meanwhile.
            guard surface.window != nil else { continue }
            drawn += 1
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
            verifyDisplayImmediately(on: sample)
            surface.enqueue(sample)
        }
        drawnSurfaceCount = drawn
        dispatchedFrameCount += 1
        framesSinceRateSample += 1
    }

    /// Records the inter-frame gap, and reports it when the item time jumps
    /// backwards — i.e. when the clip has looped.
    /// ⚠️ THE DENOMINATOR for the rate probe above.
    ///
    /// "No fast dispatches" and "the probe never ran" produce the same silence,
    /// and this session has already been fooled by that shape twice. So the
    /// heartbeat carries how many dispatches were RATED: `max=1.0x rated=58` is
    /// a measurement, `rated=0` is a broken instrument.
    private var maxRateSinceTraceSample: Double = 0
    private var ratedDispatchesSinceTraceSample = 0
    private var lastTraceSampleHostTime: CFTimeInterval = 0

    private func sampleDispatchRate(atHostTime hostTime: CFTimeInterval) {
        guard VideoPlaybackTrace.isEnabled else { return }
        if lastTraceSampleHostTime == 0 {
            lastTraceSampleHostTime = hostTime
            return
        }
        guard hostTime - lastTraceSampleHostTime >= 1 else { return }
        VideoPlaybackTrace.emit(String(
            format: "rate max=%.2fx rated=%d",
            maxRateSinceTraceSample, ratedDispatchesSinceTraceSample
        ))
        lastTraceSampleHostTime = hostTime
        maxRateSinceTraceSample = 0
        ratedDispatchesSinceTraceSample = 0
    }

    private func noteDispatch(itemTime: CMTime, hostTime: CFTimeInterval) {
        let gap = lastDispatchHostTime == 0 ? 0 : hostTime - lastDispatchHostTime
        maxGapSinceRateSample = max(maxGapSinceRateSample, gap)
        if VideoRenderFlags.logsFrameDispatch,
           lastItemTime.isValid, itemTime < lastItemTime {
            log(String(format: "WRAP %.3fs -> %.3fs gap=%.1fms",
                       lastItemTime.seconds, itemTime.seconds, gap * 1000))
        }
        // ⚠️ IS THE PICTURE RUNNING FAST? The one question a frame counter
        // cannot answer.
        //
        // Reported as "the video accelerates, as if catching up on a delay" and
        // measured off the recording's burned-in timecode at 8–10× for about a
        // third of a second. That rules nothing out on its own: media time can
        // outrun real time because the PLAYHEAD jumped, or because the display
        // is flushing a backlog of frames it could not show. The two want
        // opposite fixes, and only this ratio separates them — a playhead jump
        // moves item time without the dispatch rate changing, a display backlog
        // moves both.
        if VideoPlaybackTrace.isEnabled, lastItemTime.isValid,
           gap > 0, itemTime > lastItemTime {
            let mediaElapsed = (itemTime - lastItemTime).seconds
            let rate = mediaElapsed / gap
            if rate > 1.5 {
                // Both readings on one line: what the FRAMES did and what the
                // CLOCK did over the same interval. Equal, and the timebase is
                // racing; the frames alone, and the output is handing back
                // buffers ahead of the time it was asked for.
                let clockNow = source.lastClockTime
                let clockElapsed = (lastClockTime.isValid && clockNow.isValid)
                    ? (clockNow - lastClockTime).seconds : Double.nan
                // ⚠️ And the PLAYER's own time beside the output's reading.
                //
                // Everything so far has been read through
                // `AVPlayerItemVideoOutput.itemTime(forHostTime:)`, which is the
                // output's mapping of host time onto the item — not the player's
                // position. An adaptive stream switches rendition mid-playback,
                // and if that mapping is re-established wrongly we would be
                // ASKING for frames further ahead than playback actually is:
                // the pictures race while the player is perfectly fine. The two
                // numbers agreeing kills that idea; diverging, it names it.
                // ⚠️ And what the player says its SPEED is.
                //
                // The last question worth asking cheaply: a clock advancing six
                // times faster than real time is either obeying a rate somebody
                // set, or disagreeing with its own. `playerRate=1.00` next to a
                // 6x clock means the timebase is inconsistent with the player's
                // own declared speed — an AVFoundation behaviour to design
                // around, not a call of ours to take back. Anything above 1
                // means the opposite, and then it IS ours.
                VideoPlaybackTrace.emit(String(
                    format: "fast frames=%.3fs clock=%.3fs real=%.3fs rate=%.1fx "
                          + "out=%.3fs player=%.3fs playerRate=%.2f",
                    mediaElapsed, clockElapsed, gap, rate,
                    itemTime.seconds, player.currentTime().seconds, player.rate
                ))
            }
            maxRateSinceTraceSample = max(maxRateSinceTraceSample, rate)
            ratedDispatchesSinceTraceSample += 1
        }
        lastItemTime = itemTime
        lastClockTime = source.lastClockTime
        lastDispatchHostTime = hostTime
    }

    /// The clock reading that accompanied the previous frame — the other half of
    /// the comparison above.
    private var lastClockTime: CMTime = .invalid

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
        // `drawn` and `attached` are reported separately because they diverge,
        // and the difference is diagnostic. A discarded flight card stays in
        // the weak set until ARC collects it, so `attached` can read 5 while
        // only 2 surfaces are in a window. Logging the larger number alone
        // would read as "5 layers are being fed" — false, and exactly the kind
        // of flattering metric this issue keeps getting caught by.
        // `inWindow` is counted HERE rather than carried over from the last
        // dispatch. The carried version lagged by up to a frame and could
        // disagree with `attached` sampled at this instant, producing lines
        // whose arithmetic was impossible — which cost a measurement cycle to
        // notice. One instant, one set of numbers.
        let inWindow = surfaces.allObjects.count { $0.window != nil }
        // A renderer producing nothing is the interesting case, so it says why.
        let stalled = framesSinceRateSample == 0
        log(String(format: "fps=%.1f maxGap=%.1fms inWindow=%d attached=%d total=%d%@%@",
                   Double(framesSinceRateSample) / elapsed, maxGapSinceRateSample * 1000,
                   inWindow, surfaces.count, dispatchedFrameCount, staleSurfaceDetail,
                   stalled ? "  << " + debugPlayerState : ""))
        lastRateSampleHostTime = hostTime
        framesSinceRateSample = 0
        maxGapSinceRateSample = 0
    }

    /// Names the attached-but-not-drawn surfaces. "6 attached, 3 drawn" says
    /// there is a leak; it does not say whose, and guessing wrong costs a whole
    /// measurement cycle.
    private var debugPlayerState: String {
        #if DEBUG
        return source.debugPlayerState
        #else
        return ""
        #endif
    }

    private var staleSurfaceDetail: String {
        #if DEBUG
        // Counted per label, not listed: four recycled tiles printed as
        // "tile,tile,tile,tile" reads at a glance as one, which is how the
        // dominant source of stale surfaces got mistaken for a single entry.
        let stale = surfaces.allObjects.filter { $0.window == nil }
        guard !stale.isEmpty else { return "" }
        let counts = Dictionary(grouping: stale) { $0.debugLabel ?? "?" }
            .map { "\($0.key)x\($0.value.count)" }
            .sorted()
        return " stale=[\(counts.joined(separator: ","))]"
        #else
        return ""
        #endif
    }

    /// The luma of the buffer's centre pixel.
    ///
    /// Separates "the layer will not draw these buffers" from "these buffers
    /// are already black". Everything measurable about the pipeline has come
    /// back healthy — format, IOSurface backing, enqueue status, sample
    /// attachments, geometry — which leaves the possibility that what arrives
    /// from `AVPlayerItemVideoOutput` is black before we ever touch it. That
    /// would put the defect upstream of `AVSampleBufferDisplayLayer` entirely,
    /// and would explain why `AVPlayerLayer` (which never goes through this
    /// output) shows the same asset correctly.
    private static func centreLuma(of buffer: CVPixelBuffer) -> UInt8? {
        guard CVPixelBufferGetPlaneCount(buffer) > 0 else { return nil }
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddressOfPlane(buffer, 0) else { return nil }
        let width = CVPixelBufferGetWidthOfPlane(buffer, 0)
        let height = CVPixelBufferGetHeightOfPlane(buffer, 0)
        let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        guard width > 0, height > 0 else { return nil }
        let offset = (height / 2) * stride + (width / 2)
        return base.assumingMemoryBound(to: UInt8.self)[offset]
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
        logBufferShape(buffer)
        return created
    }

    /// Describes a decoded buffer the first time its format changes.
    ///
    /// `AVSampleBufferDisplayLayer` requires IOSurface-backed buffers and will
    /// silently drop anything else — so "is it IOSurface-backed, and in what
    /// pixel format" is the first question to ask of a layer that is enqueuing
    /// happily and showing black.
    private func logBufferShape(_ buffer: CVPixelBuffer) {
        guard VideoRenderFlags.logsFrameDispatch else { return }
        let type = CVPixelBufferGetPixelFormatType(buffer)
        let fourCC = String(bytes: (0..<4).reversed().map { UInt8((type >> ($0 * 8)) & 0xFF) },
                            encoding: .ascii) ?? "?"
        log("buffer \(CVPixelBufferGetWidth(buffer))x\(CVPixelBufferGetHeight(buffer)) "
            + "format=\(fourCC) (0x\(String(type, radix: 16))) "
            + "ioSurface=\(CVPixelBufferGetIOSurface(buffer) != nil) "
            + "luma=\(Self.centreLuma(of: buffer).map { String($0) } ?? "?")")
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

    /// Reads the `DisplayImmediately` attachment back off a finished sample
    /// buffer, once.
    ///
    /// Setting it goes through `CFDictionarySetValue` on a dictionary obtained
    /// by `unsafeBitCast` — a write that cannot fail loudly. If it silently did
    /// nothing, every frame would be queued against a control timebase that
    /// does not exist and never advances, so the layer would accept everything
    /// and display nothing: exactly the symptom. Write-then-read is the only
    /// way to know which.
    private func verifyDisplayImmediately(on sampleBuffer: CMSampleBuffer) {
        guard VideoRenderFlags.logsFrameDispatch, !hasVerifiedAttachment else { return }
        hasVerifiedAttachment = true
        let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
            as? [[CFString: Any]]
        let value = attachments?.first?[kCMSampleAttachmentKey_DisplayImmediately]
        log("DisplayImmediately readback = \(String(describing: value)) "
            + "(entries=\(attachments?.count ?? -1)) "
            + "timebase=\(String(describing: firstSurfaceTimebase()))")
    }

    private func firstSurfaceTimebase() -> CMTimebase? {
        surfaces.allObjects.first?.debugControlTimebase
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
