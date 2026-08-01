import CoreNavigation
import MediaPlayback
import UIKit

/// The single source of truth for how a post renders as a rounded media card:
/// the map pin's face *and* the hero transition's flying card are both this
/// exact component. That is what makes the transition's frame-0 handshake
/// pixel-identical by construction — there are no per-surface copies of the
/// radius, border, or crop rules left to drift apart.
///
/// Layer order (bottom → top): cover image, live video surface, border ring.
/// The card itself clips and rounds; the ring draws the pin's border above
/// whichever media surface is showing, so a live-previewing pin keeps its ring
/// too. During a flight the animator animates `frame`, `setCornerRadius`, and
/// `ringView.alpha` — everything else tracks via autoresizing.
final class PinCardView: UIView {
    /// The radius the card renders at pin size (and flies from/to).
    static let cornerRadius: CGFloat = 12
    static let ringWidth: CGFloat = 2

    /// The post's cover image, full-bleed aspect-fill. During a frame-animated
    /// flight the crop *morphs* between the pin's square and the page's
    /// full-bleed rect — CoreAnimation re-applies the fill gravity every frame.
    let imageView = UIImageView()
    /// Live-preview surface above the image, hidden until playback attaches.
    let videoRenderView = VideoRenderView()
    /// The pin's border, drawn above the media so it survives live previews.
    /// The flight fades it out as the card leaves the pin (and back in on the
    /// way home).
    let ringView = UIView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        clipsToBounds = true
        backgroundColor = .black
        layer.cornerRadius = Self.cornerRadius
        layer.cornerCurve = .continuous

        imageView.contentMode = .scaleAspectFill
        imageView.clipsToBounds = true
        imageView.backgroundColor = .secondarySystemBackground
        imageView.frame = bounds
        imageView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addSubview(imageView)

        videoRenderView.frame = bounds
        videoRenderView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        videoRenderView.clipsToBounds = true
        videoRenderView.isHidden = true
        addSubview(videoRenderView)

        ringView.isUserInteractionEnabled = false
        ringView.layer.borderWidth = Self.ringWidth
        ringView.layer.borderColor = UIColor.systemBackground.cgColor
        ringView.layer.cornerRadius = Self.cornerRadius
        ringView.layer.cornerCurve = .continuous
        ringView.frame = bounds
        ringView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addSubview(ringView)

        // `borderColor` is a CGColor and doesn't follow dark/light on its own.
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (self: Self, _) in
            self.ringView.layer.borderColor = UIColor.systemBackground.cgColor
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Rounds the card and its ring together. Both properties are
    /// UIView-animatable, so calling this inside an animation block sweeps the
    /// radius smoothly (pin 12pt ↔ device display corners).
    func setCornerRadius(_ radius: CGFloat) {
        layer.cornerRadius = radius
        ringView.layer.cornerRadius = radius
    }

    /// The soft shadow that lifts a pin card off the map — one definition used
    /// by both the annotation view and the flight's stand-in shadow.
    static func applyPinShadow(to layer: CALayer) {
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.25
        layer.shadowRadius = 4
        layer.shadowOffset = CGSize(width: 0, height: 2)
    }

    // MARK: - Flight video mode

    /// Re-anchors the live video surface for a flight. An `AVPlayerLayer`
    /// whose *bounds* animate does not track the animation smoothly — its
    /// video rect snaps — so for the flight the surface is laid out once at
    /// the destination size and driven purely by a uniform-scale transform
    /// (plus an animated center), while the card's animating bounds do the
    /// crop morph. The layer's bounds never change, so rendering stays smooth.
    func prepareVideoForFlight(destinationSize: CGSize) {
        videoRenderView.autoresizingMask = []
        videoRenderView.bounds = CGRect(origin: .zero, size: destinationSize)
    }

}

// MARK: - ZoomFlightCard

/// The pin's face IS the hero's flying card, which is what makes the frame-0
/// handshake exact rather than agreed. The shared machinery poses it through
/// this conformance and never names `PinCardView`.
extension PinCardView: ZoomFlightCard {
    var zoomRestingCornerRadius: CGFloat { Self.cornerRadius }

    /// The pin's border, which must not survive into the page pose.
    var zoomRestingChrome: UIView? { ringView }

    var zoomLiveMediaSurface: UIView? { videoRenderView.isHidden ? nil : videoRenderView }

    var zoomLiveMediaNativeSize: CGSize? { videoRenderView.nativeVideoSize }

    /// Same rule as the grid's flight card: a pin flying without live media
    /// shows its cover, which is always drawing; one flying with live media is
    /// only "drawing" while that surface is actually visible.
    var zoomLiveMediaIsDrawing: Bool {
        videoRenderView.isHidden ? true : videoRenderView.isRenderingVisibly
    }

    func adoptZoomLiveMedia(_ mirror: (UIView) -> Bool) {
        guard mirror(videoRenderView) else { return }
        // Poster covers the (usually sub-frame) gap until the mirrored layer
        // reports its first frame.
        videoRenderView.setPoster(imageView.image)
        videoRenderView.isHidden = false
    }

    func setZoomCornerRadius(_ radius: CGFloat) {
        setCornerRadius(radius)
    }

    func prepareZoomLiveMediaForFlight(destinationSize: CGSize) {
        prepareVideoForFlight(destinationSize: destinationSize)
    }

    /// A pin lifts off the map, so its flight carries the same drop shadow.
    func applyZoomRestingShadow(to layer: CALayer) {
        Self.applyPinShadow(to: layer)
    }
}
