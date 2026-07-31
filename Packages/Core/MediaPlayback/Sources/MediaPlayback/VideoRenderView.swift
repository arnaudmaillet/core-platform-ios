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
            readinessObservation = playerLayer.observe(\.isReadyForDisplay, options: [.new]) { [weak self] layer, _ in
                let ready = layer.isReadyForDisplay
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        #if DEBUG
                        self?.logReadiness(ready)
                        #endif
                        self?.updatePosterVisibility(ready: ready)
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

    private func updatePosterVisibility(ready: Bool) {
        let wasVisible = !posterView.isHidden
        posterView.isHidden = (posterView.image == nil) || ready
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
        if wasVisible != !posterView.isHidden { logPoster(visible: !posterView.isHidden) }
        #endif
    }

    // MARK: - Controller seam

    /// Releases this surface when a host swaps it out for a donated one. The
    /// controller keeps no loan for a view that is being discarded, so this
    /// only has to stop it rendering.
    public func detachForReplacement() {
        playerLayer?.player = nil
        detachFromRenderer()
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
            self.renderer?.removeSurface(self)
            self.renderer = renderer
            renderer.addSurface(self)
            return
        }
        guard let playerLayer, playerLayer.player !== player else { return }
        playerLayer.player = player
    }

    func detach() {
        playerLayer?.player = nil
        detachFromRenderer()
        // No player → nothing to display → the poster comes back.
        updatePosterVisibility(ready: false)
    }

    /// Leaves the renderer's surface set and clears the layer.
    ///
    /// Called both from `detach` and from the renderer itself when it is
    /// invalidated, so the edge is always broken from whichever side noticed
    /// first.
    func detachFromRenderer() {
        guard renderer != nil || enqueuedFrameCount > 0 else { return }
        renderer?.removeSurface(self)
        renderer = nil
        flushSampleBuffers()
        updatePosterVisibility(ready: false)
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
        if wasFirst {
            // The poster's whole job is covering the gap before the first
            // frame, and now we know precisely when that ends — no KVO, no
            // proxy, no race with a layer's internal readiness.
            updatePosterVisibility(ready: true)
            logFirstFrame()
        }
    }

    private func flushSampleBuffers() {
        guard let sampleBufferLayer else { return }
        sampleBufferLayer.sampleBufferRenderer.flush()
        enqueuedFrameCount = 0
        lastFrameHostTime = 0
    }

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
        print(String(format: "[avsbdl] %.3f %@ FIRST FRAME", CACurrentMediaTime(), name))
    }

    #if DEBUG
    var isPosterVisible: Bool { !posterView.isHidden }

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
