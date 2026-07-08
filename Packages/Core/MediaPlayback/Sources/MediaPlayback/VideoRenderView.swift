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
                MainActor.assumeIsolated { self?.updatePosterVisibility(ready: ready) }
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
        posterView.isHidden = (posterView.image == nil) || ready
    }

    // MARK: - Controller seam

    func attach(_ player: AVPlayer) { playerLayer.player = player }
    func detach() {
        playerLayer.player = nil
        // No player → nothing to display → the poster comes back.
        updatePosterVisibility(ready: false)
    }
    var isAttached: Bool { playerLayer.player != nil }

    #if DEBUG
    var isPosterVisible: Bool { !posterView.isHidden }
    #endif
}
