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
        print(String(format: "[zoom-live] %.3f %@ POSTER=%@",
                     CACurrentMediaTime(), debugLabel, visible ? "VISIBLE" : "hidden"))
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
