import AVFoundation
import CoreMedia
import QuartzCore
import UIKit

/// A view that renders whatever `VideoPlaybackController` attaches to it. It is
/// the *only* playback type a consumer (e.g. a feed cell) holds — its public
/// surface exposes no AVFoundation types, so consumers never import
/// AVFoundation (which would shadow our `MediaCore` module). The controller
/// drives attachment through the internal seam below.
///
/// A poster image sits above the player and is shown until the surface has a
/// frame to display. This removes the black flash before the first frame, and —
/// once the backend reports a still-processing asset (Phase 3) — is the surface
/// a "processing" post falls back to.
///
/// ## Two backings, one public API (#83)
///
/// Under `-avsbdl-render` the layer is an `AVSampleBufferDisplayLayer` fed by a
/// `VideoFrameRenderer`; otherwise it is the `AVPlayerLayer` this view has
/// always been. Every consumer-visible property behaves identically across the
/// two — `videoGravity` exists on both, and `mask` / `isHidden` / corner radius
/// are plain `CALayer` and never knew the difference.
///
/// Switching on `layerClass` is safe only because `VideoRenderFlags` is
/// process-constant; see the note there.
public final class VideoRenderView: UIView {
    public override class var layerClass: AnyClass {
        VideoRenderFlags.usesSampleBufferLayer ? AVSampleBufferDisplayLayer.self : AVPlayerLayer.self
    }

    private var playerLayer: AVPlayerLayer? { layer as? AVPlayerLayer }
    private var sampleBufferLayer: AVSampleBufferDisplayLayer? { layer as? AVSampleBufferDisplayLayer }

    private let posterView = UIImageView()
    /// Gates the poster fade's terminal completion — see the note in
    /// `updatePosterVisibility`.
    private var posterGeneration = 0
    private var readinessObservation: NSKeyValueObservation?

    /// The renderer feeding this surface, in sample-buffer mode. Unowned by
    /// design: the renderer travels with its pooled `AVPlayer` and outlives any
    /// single view, and it holds surfaces weakly, so this is the only strong
    /// edge and it points the safe way.
    private weak var renderer: VideoFrameRenderer?

    /// Frames actually handed to this layer since the last flush, and when the
    /// most recent one landed.
    ///
    /// This exists because of a specific measurement failure recorded in #83:
    /// `AVPlayerLayer.isReadyForDisplay` stays **true** on a layer that has lost
    /// the render slot to another layer on the same player — it keeps reporting
    /// ready while showing a frozen frame, so the acceptance harness's `dips`
    /// gate passed over surfaces the viewer saw freeze. Twice, a conclusion in
    /// that work was invalidated by a probe that could not see what it claimed
    /// to measure.
    ///
    /// A frame counter cannot have that failure mode. "Did this surface receive
    /// a frame in the last N milliseconds" is liveness itself rather than a
    /// proxy for it, and it is only answerable because we now dispatch the
    /// frames ourselves.
    public private(set) var enqueuedFrameCount = 0
    public private(set) var lastFrameHostTime: CFTimeInterval = 0

    public init() {
        super.init(frame: .zero)
        backgroundColor = .black

        posterView.contentMode = .scaleAspectFill
        posterView.clipsToBounds = true
        posterView.isUserInteractionEnabled = false
        posterView.frame = bounds
        posterView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addSubview(posterView)

        if let sampleBufferLayer {
            sampleBufferLayer.videoGravity = .resizeAspectFill
            updatePosterVisibility(ready: false) // no frames yet → hidden (no image either)
        } else if let playerLayer {
            playerLayer.videoGravity = .resizeAspectFill
            updatePosterVisibility(ready: playerLayer.isReadyForDisplay)
            readinessObservation = playerLayer.observe(\.isReadyForDisplay, options: [.new]) { [weak self] _, _ in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        // Re-read at delivery, never the value captured when
                        // the KVO fired: a `detach` can interleave between the
                        // two, and applying a stale `true` hides the poster
                        // over a layer that no longer has a player — a
                        // one-frame black pop with every other signal healthy.
                        let ready = self.playerLayer?.isReadyForDisplay ?? false
                        #if DEBUG
                        self.logReadiness(ready)
                        #endif
                        self.updatePosterVisibility(ready: ready)
                        // The player-layer half of `revealOnFirstFrame`: this
                        // KVO is the only "first frame" signal this backing
                        // has, so it must drive the reveal exactly as
                        // `enqueue` does on the other one.
                        if ready, self.isAwaitingFirstFrameToReveal {
                            self.isAwaitingFirstFrameToReveal = false
                            self.reveal(crossFading: true)
                        }
                    }
                }
            }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// The poster shown until the video is ready to display. Pass `nil` to clear.
    public func setPoster(_ image: UIImage?) {
        posterView.image = image
        updatePosterVisibility(ready: isReadyForDisplay)
    }

    /// Says the picture is waiting for playback to reach it.
    ///
    /// ⚠️ AFTER A DELAY, never immediately. Most catch-ups last a few frames and
    /// resolve before anyone could read a spinner; showing one for those would
    /// replace a defect nobody noticed with a flicker everybody does. The
    /// indicator is for the case the viewer actually experiences as a wait.
    func setCatchingUp(_ catchingUp: Bool) {
        guard catchingUp != isCatchingUp else { return }
        isCatchingUp = catchingUp
        catchUpWorkItem?.cancel()
        catchUpWorkItem = nil
        guard catchingUp else {
            spinner?.stopAnimating()
            return
        }
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.isCatchingUp else { return }
            self.installSpinnerIfNeeded()
            self.spinner?.startAnimating()
        }
        catchUpWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.catchUpIndicatorDelay, execute: work)
    }

    /// How long a catch-up must last before it is worth telling the viewer.
    private static let catchUpIndicatorDelay: TimeInterval = 0.4
    private var isCatchingUp = false
    private var catchUpWorkItem: DispatchWorkItem?
    private var spinner: UIActivityIndicatorView?

    /// Built on first use: a timeline of stills must never allocate one.
    private func installSpinnerIfNeeded() {
        guard spinner == nil else { return }
        let view = UIActivityIndicatorView(style: .medium)
        view.color = .white
        view.hidesWhenStopped = true
        view.isUserInteractionEnabled = false
        view.translatesAutoresizingMaskIntoConstraints = false
        addSubview(view)
        NSLayoutConstraint.activate([
            view.centerXAnchor.constraint(equalTo: centerXAnchor),
            view.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        spinner = view
    }

    private func updatePosterVisibility(ready: Bool) {
        let wasVisible = !posterView.isHidden
        let shouldHide = (posterView.image == nil) || ready
        #if DEBUG
        // `-poster-log`: every visibility decision, unconditionally. The
        // transition-only `logPoster` has a blind window before a surface
        // starts flight-tracking, and that window is exactly where the
        // cold-open poster vanished — a defect the transition logs reported
        // as healthy. This is the trace that convicted it.
        if ProcessInfo.processInfo.arguments.contains("-poster-log") {
            print(String(format: "[poster] %.3f %@ ready=%@ image=%@ wasVisible=%@ -> shouldHide=%@",
                         CACurrentMediaTime(), debugLabelOrAnonymous,
                         ready ? "Y" : "n", posterView.image == nil ? "nil" : "set",
                         wasVisible ? "Y" : "n", shouldHide ? "Y" : "n"))
        }
        #endif
        // Faded out, not switched off, for the same reason the surface itself
        // cross-fades: the poster and the video are two different images in the
        // same place, and swapping them in one frame is a visible cut. Fading
        // in is still immediate — a poster only appears when there is nothing
        // else to show, so there is nothing to blend against and nothing to
        // gain by easing it.
        //
        // Two guards on the fade, and they are THE cold-open black screen:
        //
        //  - `image != nil`: only a poster with pixels fades; an imageless one
        //    hides instantly. The poster starts life unhidden, so the very
        //    first `setPoster(nil)` of a cell's configure took the fade path —
        //    inside `cellForItemAt`, where UIKit disables animations, so the
        //    completion fired `finished == true` DEFERRED, past the real
        //    poster's install one line later.
        //  - the generation gate on the completion: a hide's terminal state
        //    must never land after a later call re-showed the poster. The
        //    deferred completion above did exactly that — an unlogged
        //    `isHidden = true` stamped onto a freshly shown poster, leaving
        //    every cold video page with a set-but-hidden cover and a BLACK
        //    media area until its first decoded frame. Traced end to end
        //    under `-poster-log`; the same stale-completion class as
        //    `visibilityGeneration`, one level down.
        posterGeneration += 1
        let generation = posterGeneration
        if wasVisible, shouldHide, posterView.image != nil {
            posterView.isHidden = false
            UIView.animate(withDuration: Self.revealDuration, delay: 0,
                           options: [.allowUserInteraction, .beginFromCurrentState]) {
                self.posterView.alpha = 0
            } completion: { finished in
                if finished, generation == self.posterGeneration {
                    self.posterView.isHidden = true
                }
            }
        } else {
            posterView.layer.removeAllAnimations()
            posterView.alpha = 1
            posterView.isHidden = shouldHide
        }
        // With neither a decoded frame nor a poster there is nothing to show,
        // and a black fill is not "nothing" — it covers whatever the host put
        // behind this surface. A grid tile puts its cover image there and then
        // unhides the surface at `play`, so between the unhide and the first
        // frame the black floor replaced the cover for ~1.2s, measured. That is
        // the tile going dark, and it is not a transition bug: it happens at
        // rest, on every tile that starts playing before its cover has loaded.
        //
        // The dark floor is deliberate where it earns its keep — under a poster
        // that fails to render, and under video whose aspect leaves bars — so
        // it comes back the moment there is anything to floor.
        backgroundColor = (posterView.image == nil && !ready) ? .clear : .black
        #if DEBUG
        if wasVisible != !shouldHide { logPoster(visible: !shouldHide) }
        #endif
    }

    // MARK: - Controller seam

    /// Releases this surface when a host swaps it out for a donated one. The
    /// controller keeps no loan for a view that is being discarded, so this
    /// only has to stop it rendering.
    public func detachForReplacement() {
        playerLayer?.player = nil
        detachFromRenderer(reason: "detachForReplacement")
    }

    /// The player currently bound to this layer, for callers that must avoid
    /// re-assigning the same one — see `attach`.
    var attachedPlayer: AVPlayer? { playerLayer?.player ?? renderer?.player }

    /// Binds `player` for display, skipping the assignment when it is already
    /// bound.
    ///
    /// In sample-buffer mode `renderer` is non-nil and this is pure
    /// bookkeeping: the surface joins the renderer's set and starts receiving
    /// the same frames every other attached surface gets. **Nothing is
    /// re-bound, so nothing goes dark** — which is the entire reason for the
    /// pivot.
    ///
    /// In player-layer mode this is the historical behaviour, and the guard is
    /// load-bearing: re-assigning an identical player RESETS the layer,
    /// `isReadyForDisplay` drops back to false and the surface is blank until
    /// it decodes again — measured at 150ms, landing exactly on the flight's
    /// completion frame. That was the flash at the END of the zoom once the
    /// surface itself was being handed along instead of re-created.
    func attach(_ player: AVPlayer, renderer: VideoFrameRenderer? = nil) {
        if let renderer {
            guard self.renderer !== renderer else { return }
            // ⚠️ A NEW SOURCE MAKES WHAT IS QUEUED STALE.
            //
            // The companion to the flush on resume, and it exists because the
            // card reaches the same state by paths that never pause: a player
            // reclaimed after a dismissal, a surface joining a running clip, a
            // mirror, a handoff. Each rebinds this view to a different clock
            // while frames from the previous one are still waiting — and those,
            // shown, are the video appearing to hurry.
            //
            // Only when the renderer actually CHANGES. A rebind to the same
            // source is a no-op above and must stay one: flushing a healthy
            // playing surface would cost it the frames it is about to show.
            flushPendingSamples()
            self.renderer?.removeSurface(self)
            self.renderer = renderer
            renderer.addSurface(self)
            return
        }
        guard let playerLayer, playerLayer.player !== player else { return }
        playerLayer.player = player
    }

    /// Joins `sibling`'s playback directly — the same renderer in
    /// sample-buffer mode, the same player in layer mode — for callers that
    /// know WHICH surface they must mirror rather than which URL. The seam
    /// `attachSurface(_:alongsideSurface:)` needs when the sibling holds no
    /// pool loan (a surface that JOINED its playback has no registration for
    /// a URL lookup to find). Returns false when the sibling is bound to
    /// nothing.
    func attachAlongside(_ sibling: VideoRenderView) -> Bool {
        if let renderer = sibling.renderer {
            attach(renderer.player, renderer: renderer)
            return true
        }
        if let player = sibling.playerLayer?.player {
            attach(player)
            return true
        }
        return false
    }

    func detach(reason: String = "detach") {
        playerLayer?.player = nil
        detachFromRenderer(reason: reason)
        // No player → nothing to display → the poster comes back.
        updatePosterVisibility(ready: false)
    }

    /// Leaves the renderer's surface set and clears the layer.
    ///
    /// Called both from `detach` and from the renderer itself when it is
    /// invalidated, so the edge is always broken from whichever side noticed
    /// first.
    func detachFromRenderer(reason: String = "?") {
        guard renderer != nil || enqueuedFrameCount > 0 else { return }
        #if DEBUG
        // Names WHO took this surface away. A surface losing its renderer is
        // ordinary teardown almost everywhere and a defect during a flight, and
        // the two are indistinguishable from the surface's own state — which is
        // why three suspects in a row fit the evidence and were wrong.
        if VideoRenderFlags.logsFrameDispatch {
            print(String(format: "[avsbdl] %.3f %@ DETACHED by %@ (frames=%d)",
                         CACurrentMediaTime(), debugLabelOrAnonymous, reason, enqueuedFrameCount))
        }
        #endif
        renderer?.removeSurface(self)
        renderer = nil
        // A flush empties the layer, so it must be COVERED before it happens or
        // the surface goes black on the spot. There are two ways to cover it
        // and the right one depends on whether this surface owns a poster:
        //
        //  - With a poster, raise it. The poster is a subview ABOVE the layer,
        //    so the emptied layer is hidden behind the cover and the viewer
        //    sees the still, not black. This is the full-screen feed, where
        //    `SnapMediaCardView` puts the cover INSIDE the render view and
        //    hides its own image view — the render view IS the cover there.
        //  - Without one, hide the view. An empty layer with nothing over it is
        //    a black rectangle, which is what blanked four visible tiles at
        //    once when `beginHandoff` stopped them.
        //
        // Hiding unconditionally got the second case right and the first badly
        // wrong: `play` detaches before it attaches, so tapping into a video
        // hid the cover for the entire buffering window — cover, then black,
        // then video.
        //
        // A surface the host has already hidden is left alone; un-hiding one
        // here would undo a deliberate fade-out.
        let wasVisible = !isHidden && alpha > 0
        isAwaitingFirstFrameToReveal = false
        updatePosterVisibility(ready: false)
        if wasVisible, posterView.image == nil {
            isHidden = true
        }
        flushSampleBuffers()
    }

    var isAttached: Bool { playerLayer?.player != nil || renderer != nil }

    /// Whether the surface has a decoded frame on screen.
    ///
    /// In sample-buffer mode this is a fact — we counted the frames. In
    /// player-layer mode it is `AVPlayerLayer`'s own flag, which a freshly
    /// attached layer reports false for even when its player is mid-playback
    /// (the new layer needs its own render cycle), and which stays true on a
    /// layer showing a frozen frame. See `enqueuedFrameCount`.
    public var isReadyForDisplay: Bool {
        if sampleBufferLayer != nil { return enqueuedFrameCount > 0 }
        return playerLayer?.isReadyForDisplay ?? false
    }

    // MARK: - Reveal gating

    /// Set while the surface is waiting for its first frame before becoming
    /// visible. See `revealOnFirstFrame`.
    private var isAwaitingFirstFrameToReveal = false

    /// Bumped on every reveal/hide entry, so a terminal completion from a
    /// SUPERSEDED transition can never apply. The direct-set reveal path does
    /// not cancel an in-flight UIView fade (assigning a property replaces the
    /// model value but the attached animation runs to its natural end,
    /// reporting `finished == true`), so without this a hide's fade-out could
    /// outlive a reveal that interleaved within its 33ms window and stamp
    /// `isHidden = true` on a surface whose model state says it is showing —
    /// an invisible surface that then fails `isRenderingVisibly` and holds a
    /// landing card up to its ceiling before popping the cover.
    private var visibilityGeneration = 0

    /// Reveals this surface now if it already has a frame, otherwise keeps it
    /// hidden and reveals it the instant one arrives.
    ///
    /// **The cold-flight fix.** A surface joining a running playback is primed
    /// with the most recent frame — but only if one exists. On the first flight
    /// of a tile whose playback has just started, the renderer has not
    /// dispatched anything yet, so the new surface is empty. Unhiding it there
    /// replaces whatever the host was showing (a cover image) with an empty
    /// surface for one decode interval: the snap on the first iteration, gone
    /// by the second because by then a frame exists to prime with.
    ///
    /// Hosts call this instead of `isHidden = false` so the rule is one line
    /// and cannot be got wrong per site: **never show a surface that has
    /// nothing to show.** Whatever is behind it — the tile's cover, the flight
    /// card's cover — stays visible for those few milliseconds instead, which
    /// is the same image the viewer was already looking at.
    public func revealOnFirstFrame() {
        // `isReadyForDisplay`, NOT `enqueuedFrameCount`. The counter only ever
        // increments in sample-buffer mode, so gating on it left every surface
        // on the `AVPlayerLayer` path hidden forever: no tile showed video at
        // all, only its cover, and every transition was covers moving around.
        // That is the default path — the one that ships — and it is why fading
        // the poster changed nothing: the surface was never revealed to fade
        // against.
        guard !isReadyForDisplay else {
            isAwaitingFirstFrameToReveal = false
            reveal(crossFading: false)
            return
        }
        // A POSTERED surface is not empty, and must not be hidden. The rule
        // this method enforces is "never show a surface with nothing to
        // show" — but the poster is something: it sits above the layer and
        // `updatePosterVisibility` retires it the moment the first frame
        // lands. Hiding the VIEW buries the poster with it, and for hosts
        // that keep their cover INSIDE the surface (the feed page — the
        // render view IS the cover there) that left the cell's black floor
        // as the media area for the whole decode start-up. Traced on device
        // and in `-media-log` as the cold-open black screen: poster=SHOWN at
        // configure, entombed by this hide at warm-attach, black until the
        // first decoded frame seconds later.
        if posterView.image != nil, !posterView.isHidden {
            isAwaitingFirstFrameToReveal = false
            reveal(crossFading: false)
            return
        }
        visibilityGeneration += 1
        isAwaitingFirstFrameToReveal = true
        isHidden = true
        alpha = 0
    }

    /// How long the surface takes to replace whatever is behind it. Two frames
    /// at 60Hz — long enough that the swap is a blend rather than a cut, short
    /// enough that it reads as instant.
    private static let revealDuration: TimeInterval = 1.0 / 30

    /// Brings the surface up over whatever is behind it — the host's cover
    /// image, in every case that matters.
    ///
    /// **This is the thumbnail pop.** A cover sits permanently beneath the
    /// video surface (the grid cell's `imageView`, the flight card's), so the
    /// surface's visibility IS the cover's visibility, inverted. Toggling
    /// `isHidden` therefore cuts between two different images in a single
    /// frame, and on a real device that reads as the thumbnail flicking in —
    /// on BOTH legs, because both legs hold a surface back until it has a
    /// frame.
    ///
    /// Cross-fading makes the same swap continuous: for two frames the cover
    /// and the video are blended, and there is no frame where the cover is the
    /// only thing on screen after the video was.
    private func reveal(crossFading: Bool) {
        visibilityGeneration += 1
        let wasHidden = isHidden || alpha < 1
        isHidden = false
        guard crossFading, wasHidden else {
            // "opacity" is the key a UIView alpha animation actually lands
            // under — a direct set replaces the model value but leaves an
            // in-flight fade running, so it has to be removed by its real
            // name. (This line once said "reveal", which matched nothing.)
            layer.removeAnimation(forKey: "opacity")
            alpha = 1
            return
        }
        UIView.animate(withDuration: Self.revealDuration, delay: 0,
                       options: [.allowUserInteraction, .beginFromCurrentState]) {
            self.alpha = 1
        }
    }

    /// The media's NATIVE pixel dimensions, or nil before the item resolves
    /// them.
    ///
    /// Read from `AVPlayerItem.presentationSize`, which both backings share —
    /// the player owns the item either way, so this does not depend on which
    /// layer is doing the drawing.
    public var nativeVideoSize: CGSize? {
        guard let size = attachedPlayer?.currentItem?.presentationSize,
              size.width > 0, size.height > 0
        else { return nil }
        return size
    }

    /// Whether this surface has ever displayed a frame since its last flush.
    public var hasFrame: Bool { isReadyForDisplay }

    /// A name for tracing, or a placeholder when the host never set one.
    var debugLabelOrAnonymous: String {
        #if DEBUG
        return debugLabel ?? "unnamed"
        #else
        return "surface"
        #endif
    }

    /// Whether this surface is drawing AND actually opaque on screen right now.
    ///
    /// The signal a handoff must wait on. `isReadyForDisplay && !isHidden` is
    /// not enough once the reveal cross-fades: `reveal` clears `isHidden` and
    /// THEN animates alpha 0 → 1, so those two go true while the surface is
    /// still transparent. A landing gated on them releases the flight card
    /// two frames early and the host's cover shows through — a thumbnail
    /// flicker at the exact end of the flight.
    ///
    /// Reads the PRESENTATION layer, not `alpha`. During a UIView animation
    /// `alpha` already holds the target value, so it reports 1 the moment the
    /// fade is scheduled and would carry the same lie.
    public var isRenderingVisibly: Bool {
        guard isReadyForDisplay, !isHidden else { return false }
        let opacity = layer.presentation()?.opacity ?? Float(alpha)
        return opacity > 0.99
    }

    /// Whether this surface is compositing SOMETHING real — a decoded frame
    /// drawing at full opacity, or its poster standing in over the layer.
    ///
    /// The present landing's reveal gates on this. `isRenderingVisibly` alone
    /// is the wrong question there: a page that has not started playback yet
    /// legitimately shows its POSTER, and holding a reveal hostage to decoded
    /// frames would freeze the flight card over a perfectly presentable page.
    /// What the landing must never do is swap the card for a media area with
    /// NEITHER — that is the black beat measured on device (run 2 of the
    /// frame-0 investigation: card removed, feed revealed, nothing behind it).
    public var isCompositingContent: Bool {
        if isRenderingVisibly { return true }
        guard !isHidden, alpha > 0.01 else { return false }
        return posterView.image != nil && !posterView.isHidden && posterView.alpha > 0.01
    }

    /// Takes the surface down over whatever is behind it, rather than
    /// switching it off.
    ///
    /// The mirror image of `revealOnFirstFrame`, and it matters at exactly the
    /// moment a flight starts: `beginHandoff` stops every tile that is not
    /// flying, and a binary hide there snaps each of their covers back in one
    /// frame — several thumbnails popping at once, on the grid, as the flight
    /// leaves. Fading hands the tile back to its cover continuously.
    public func hideCrossFading() {
        isAwaitingFirstFrameToReveal = false
        visibilityGeneration += 1
        let generation = visibilityGeneration
        guard !isHidden, alpha > 0 else {
            isHidden = true
            return
        }
        UIView.animate(withDuration: Self.revealDuration, delay: 0,
                       options: [.allowUserInteraction, .beginFromCurrentState]) {
            self.alpha = 0
        } completion: { finished in
            // The generation gate is the half `finished` cannot cover — see
            // `visibilityGeneration`.
            if finished, generation == self.visibilityGeneration {
                self.isHidden = true
            }
        }
    }

    // MARK: - Frame intake

    /// Displays one frame. Called by `VideoFrameRenderer` on the display link.
    func enqueue(_ sampleBuffer: CMSampleBuffer) {
        guard let sampleBufferLayer else { return }
        let renderer = sampleBufferLayer.sampleBufferRenderer

        // Both recovery cases are checked here rather than through
        // notifications, because here is the only moment the answer matters and
        // both are plain property reads. `requiresFlushToResumeDecoding` is set
        // when the app is backgrounded — without this a surface comes back from
        // the app switcher permanently black, which would block every other
        // Phase 1 observation before it could be made.
        if renderer.requiresFlushToResumeDecoding || renderer.status == .failed {
            flushSampleBuffers()
        }
        guard renderer.isReadyForMoreMediaData else { return }

        renderer.enqueue(sampleBuffer)
        // Enqueue is fire-and-forget: a buffer the layer cannot display is
        // dropped silently and the FRAME COUNT STILL GOES UP. That is how a
        // surface can report 30fps of dispatch while showing black. Check the
        // renderer's own verdict instead of trusting the count.
        if renderer.status == .failed {
            logEnqueueFailure(renderer.error)
        }
        let wasFirst = enqueuedFrameCount == 0
        enqueuedFrameCount += 1
        lastFrameHostTime = CACurrentMediaTime()
        if wasFirst, isAwaitingFirstFrameToReveal {
            isAwaitingFirstFrameToReveal = false
            reveal(crossFading: true)
        }
        if wasFirst {
            // The poster's whole job is covering the gap before the first
            // frame, and now we know precisely when that ends — no KVO, no
            // proxy, no race with a layer's internal readiness.
            updatePosterVisibility(ready: true)
            logFirstFrame()
        }
    }

    /// Drops frames queued but not yet shown, keeping the one on screen.
    ///
    /// ⚠️ For RESUMING, and the distinction from a teardown flush is the whole
    /// point: `flush()` discards what is pending and leaves the displayed image
    /// alone, so the surface holds its frozen frame until the next dispatch
    /// replaces it with the CURRENT one.
    ///
    /// Why a resume needs it: a clip that went on running while the viewer was
    /// elsewhere — which is exactly what a parked player does, deliberately, so
    /// the post it was handed to keeps the playhead — comes back further along
    /// than the frame the surface froze on. Whatever is still queued belongs to
    /// the past. Shown, it reads as the video hurrying to catch up; dropped, the
    /// picture simply resumes where the clip actually is.
    ///
    /// A short clip loops, so the gap wraps and stays small — which is why this
    /// was reported on a long stream and not on a ten-second one.
    func flushPendingSamples() {
        guard let sampleBufferLayer else { return }
        sampleBufferLayer.sampleBufferRenderer.flush()
        enqueuedFrameCount = 0
    }

    private func flushSampleBuffers() {
        guard let sampleBufferLayer else { return }
        #if DEBUG
        // A flush empties the layer, so a VISIBLE surface that is flushed goes
        // black on the spot. That is the shape of the remaining dismissal
        // defect — one black frame on the feed page, chrome still lit — so the
        // question is whether anything flushes a surface the viewer can see,
        // and when. Logged with reachability because a flush on an off-screen
        // surface is ordinary teardown and not interesting.
        if VideoRenderFlags.logsFrameDispatch, enqueuedFrameCount > 0 {
            print(String(format: "[avsbdl] %.3f %@ FLUSH frames=%d onScreen=%@ %@",
                         CACurrentMediaTime(), debugLabel ?? "surface", enqueuedFrameCount,
                         isEffectivelyOnScreen ? "YES" : "no", debugVisibilityDetail))
        }
        #endif
        sampleBufferLayer.sampleBufferRenderer.flush()
        enqueuedFrameCount = 0
        lastFrameHostTime = 0
    }

    /// The layer's control timebase, if it has one. Nil is expected and correct
    /// under `DisplayImmediately`; it only matters as the other half of the
    /// question "is anything scheduling these frames".
    var debugControlTimebase: CMTimebase? { sampleBufferLayer?.controlTimebase }

    private func logEnqueueFailure(_ error: Error?) {
        guard VideoRenderFlags.logsFrameDispatch else { return }
        print(String(format: "[avsbdl] %.3f ENQUEUE FAILED: %@",
                     CACurrentMediaTime(), String(describing: error)))
    }

    private func logFirstFrame() {
        guard VideoRenderFlags.logsFrameDispatch else { return }
        #if DEBUG
        let name = debugLabel ?? "surface"
        #else
        let name = "surface"
        #endif
        // Geometry with the first frame, because a correctly-fed layer at the
        // wrong size draws exactly what an unfed one does: nothing.
        print(String(format: "[avsbdl] %.3f %@ FIRST FRAME view=%@ layer=%@ gravity=%@ hidden=%@ alpha=%.2f super=%@",
                     CACurrentMediaTime(), name,
                     NSCoder.string(for: frame), NSCoder.string(for: layer.bounds),
                     sampleBufferLayer?.videoGravity.rawValue ?? "-",
                     isHidden ? "true" : "false", alpha,
                     superview.map { "\(type(of: $0))" } ?? "nil"))
    }

    #if DEBUG
    var isPosterVisible: Bool { !posterView.isHidden && posterView.alpha > 0.01 }

    /// Everything that decides whether this surface shows anything, in one
    /// string. For tracing who blanks a media area: a black region is always
    /// some combination of these, and reading them together is what separates
    /// "hidden" from "empty layer" from "poster cleared".
    public var debugSurfaceState: String {
        let poster = posterView.image == nil
            ? "nil" : (isPosterVisible ? "SHOWN" : "set/hidden")
        return String(format: "hidden=%@ alpha=%.2f poster=%@ frames=%d bg=%@",
                      isHidden ? "Y" : "N", alpha, poster, enqueuedFrameCount,
                      backgroundColor == .clear ? "clear" : "black")
    }

    /// Names this surface in `-zoom-live-log` output (e.g. "tile", "card").
    public var debugLabel: String?

    /// Set only on the surfaces taking part in a hero flight. Background
    /// teardowns — the other autoplaying tiles being stopped as the grid is
    /// covered — are ordinary and drowned the signal, so they stay unlogged.
    public var debugTracksFlight = false

    /// The poster covering the layer IS the thumbnail flash. `isReadyForDisplay`
    /// is only a proxy for it — and a lossy one: a layer that has lost the render
    /// slot to another layer on the same player keeps reporting ready while it
    /// shows a frozen frame. Log the thing itself, so a flight can be judged on
    /// what the viewer saw.
    private func logPoster(visible: Bool) {
        guard let debugLabel, debugTracksFlight,
              ProcessInfo.processInfo.arguments.contains("-zoom-live-log")
        else { return }
        // A poster that becomes visible on a surface nobody can see is not a
        // flash. Distinguishing the two needs the surface's actual on-screen
        // state at that instant, not an inference from where it sits in the
        // teardown — so the reachability is logged with the event and the
        // question stops being a judgement call.
        print(String(format: "[zoom-live] %.3f %@#%@ POSTER=%@ onScreen=%@ %@",
                     CACurrentMediaTime(), debugLabel, debugInstanceTag,
                     visible ? "VISIBLE" : "hidden",
                     isEffectivelyOnScreen ? "YES" : "no", debugVisibilityDetail))
    }

    /// A short per-instance tag. The feed recycles page cells, so several
    /// distinct surfaces all label themselves "page"; without this, four poster
    /// events look like one surface flickering four times rather than four
    /// separate cells each doing it once.
    private var debugInstanceTag: String {
        String(UInt(bitPattern: ObjectIdentifier(self).hashValue) % 0x1000, radix: 16)
    }

    /// Whether this surface could actually be seen right now: in a window, and
    /// no ancestor hiding or fading it to nothing.
    ///
    /// Deliberately does NOT claim to answer "did the viewer see it" — another
    /// view can still be drawn over the top, and a hero flight is precisely the
    /// situation where something usually is. It answers the weaker question it
    /// can answer honestly, which is enough to dismiss the events that are
    /// unreachable outright.
    private var isEffectivelyOnScreen: Bool {
        guard window != nil else { return false }
        var node: UIView? = self
        var alpha: CGFloat = 1
        while let view = node {
            if view.isHidden { return false }
            alpha *= view.alpha
            node = view.superview
        }
        return alpha > 0.01
    }

    private var debugVisibilityDetail: String {
        var alpha: CGFloat = 1
        var hiddenBy = "-"
        var node: UIView? = self
        while let view = node {
            alpha *= view.alpha
            if view.isHidden, hiddenBy == "-" { hiddenBy = "\(type(of: view))" }
            node = view.superview
        }
        return String(format: "window=%@ alpha=%.2f hiddenBy=%@",
                      window == nil ? "nil" : "yes", alpha, hiddenBy)
    }

    private func logReadiness(_ ready: Bool) {
        guard let debugLabel, debugTracksFlight,
              ProcessInfo.processInfo.arguments.contains("-zoom-live-log")
        else { return }
        print(String(format: "[zoom-live] %.3f %@ readyForDisplay=%@",
                     CACurrentMediaTime(), debugLabel, ready ? "true" : "false"))
    }
    #endif
}
