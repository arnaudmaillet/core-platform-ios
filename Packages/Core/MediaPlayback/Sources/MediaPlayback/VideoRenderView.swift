import AVFoundation
import UIKit

/// A view that renders whatever `VideoPlaybackController` attaches to it. It is
/// the *only* playback type a consumer (e.g. a feed cell) holds — its public
/// surface exposes no AVFoundation types, so consumers never import
/// AVFoundation (which would shadow our `MediaCore` module). The controller
/// drives attachment through the internal seam below.
///
/// A poster image sits above the player and is shown until the player has a
/// frame to display (`AVPlayerLayer.isReadyForDisplay`). This removes the black
/// flash before the first frame, and — once the backend reports a still-
/// processing asset (Phase 3) — is the surface a "processing" post falls back to.
public final class VideoRenderView: UIView {
    public override class var layerClass: AnyClass { AVPlayerLayer.self }
    private var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }

    private let posterView = UIImageView()
    private var readinessObservation: NSKeyValueObservation?

    public init() {
        super.init(frame: .zero)
        backgroundColor = .black
        playerLayer.videoGravity = .resizeAspectFill

        posterView.contentMode = .scaleAspectFill
        posterView.clipsToBounds = true
        posterView.isUserInteractionEnabled = false
        posterView.frame = bounds
        posterView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addSubview(posterView)
        updatePosterVisibility(ready: playerLayer.isReadyForDisplay) // no image yet → hidden

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

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// The poster shown until the video is ready to display. Pass `nil` to clear.
    public func setPoster(_ image: UIImage?) {
        posterView.image = image
        updatePosterVisibility(ready: playerLayer.isReadyForDisplay)
    }

    private func updatePosterVisibility(ready: Bool) {
        let wasVisible = !posterView.isHidden
        posterView.isHidden = (posterView.image == nil) || ready
        #if DEBUG
        // The poster covering the layer IS the thumbnail flash. Readiness is a
        // proxy for it; this is the thing itself, so a flight can be judged on
        // what the viewer saw rather than on what the layer reported.
        if wasVisible != !posterView.isHidden { logPoster(visible: !posterView.isHidden) }
        #endif
    }

    // MARK: - Controller seam

    /// Releases this surface when a host swaps it out for a donated one. The
    /// controller keeps no loan for a view that is being discarded, so this
    /// only has to stop it rendering.
    public func detachForReplacement() {
        playerLayer.player = nil
    }

    /// The player currently bound to this layer, for callers that must avoid
    /// re-assigning the same one — see `attach`.
    var attachedPlayer: AVPlayer? { playerLayer.player }

    /// Binds `player`, skipping the assignment when it is already bound.
    ///
    /// Re-assigning an identical player RESETS the layer: `isReadyForDisplay`
    /// drops back to false and the surface is blank until it decodes again —
    /// measured at 150ms, landing exactly on the flight's completion frame.
    /// That was the flash at the END of the zoom once the surface itself was
    /// being handed along instead of re-created.
    func attach(_ player: AVPlayer) {
        guard playerLayer.player !== player else { return }
        playerLayer.player = player
    }
    func detach() {
        playerLayer.player = nil
        // No player → nothing to display → the poster comes back.
        updatePosterVisibility(ready: false)
    }
    var isAttached: Bool { playerLayer.player != nil }

    /// Whether the layer has a decoded frame on screen. A freshly attached
    /// `AVPlayerLayer` is NOT ready even when its player is mid-playback — the
    /// new layer needs its own render cycle — which is the whole reason a
    /// mirrored flight card can start out blank.
    public var isReadyForDisplay: Bool { playerLayer.isReadyForDisplay }

    #if DEBUG
    /// Whether the poster is currently covering the video — i.e. exactly the
    /// "thumbnail flash" the hero work is chasing. Public so an app-level probe
    /// can sample it per frame across a transition.
    public var isPosterVisible: Bool { !posterView.isHidden }

    /// Names this surface in `-zoom-live-log` output (e.g. "tile", "card").
    public var debugLabel: String?

    /// Set only on the surfaces taking part in a hero flight. Background
    /// teardowns — the other autoplaying tiles being stopped as the grid is
    /// covered — are ordinary and drowned the signal, so they stay unlogged.
    public var debugTracksFlight = false

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
