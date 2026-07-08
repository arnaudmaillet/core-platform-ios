import AVFoundation
import UIKit

/// A view that renders whatever `VideoPlaybackController` attaches to it. It is
/// the *only* playback type a consumer (e.g. a feed cell) holds — its public
/// surface exposes no AVFoundation types, so consumers never import
/// AVFoundation (which would shadow our `MediaCore` module). The controller
/// drives attachment through the internal seam below.
public final class VideoRenderView: UIView {
    public override class var layerClass: AnyClass { AVPlayerLayer.self }
    private var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }

    public init() {
        super.init(frame: .zero)
        backgroundColor = .black
        playerLayer.videoGravity = .resizeAspectFill
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Controller-only: bind/unbind the player behind this view's layer.
    func attach(_ player: AVPlayer) { playerLayer.player = player }
    func detach() { playerLayer.player = nil }
    var isAttached: Bool { playerLayer.player != nil }
}
