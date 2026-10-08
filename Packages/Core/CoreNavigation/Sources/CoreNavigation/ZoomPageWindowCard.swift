import UIKit

/// The flying unit for a page that FITS its picture (`ZoomPageFraming`): a
/// page window — clipped, rounded, page-shaped at the page end — holding the
/// page's backdrop and, over it, the source's own card as the picture.
///
/// ⚠️ THE WINDOW IS WHAT FLIES. Its frame runs between the source's tile rect
/// and the page rect exactly as the filling hero's card always has, so every
/// driver that moves "the card" — the present and tap-back springs, the grab's
/// centre and dip, the mid-air catch's transform and scrub, the landing cover,
/// every teardown — moves the whole composition by construction, and none of
/// them had to learn a second rect. (#255 flew the picture's FITTED rect
/// instead, inside an unclipped page-shaped box; on screen that is a small
/// letterboxed rectangle crossing the screen, and it was rejected.)
///
/// **What is inside, end to end.**
///
/// - At the TILE end the picture's card is the whole window: the source's own
///   aspect-fill crop, pixel for pixel the tile it takes off from. The backdrop
///   is behind it and entirely covered.
/// - At the PAGE end the picture's card is the fitted rect, centred, and the
///   backdrop fills the rest: the page's composition, pixel for pixel the page
///   it lands on (square picture corners; the window carries the display's).
/// - Between the two the picture's card moves linearly from one rect to the
///   other on the flight's own spring, so the crop OPENS UP as the window
///   grows and the backdrop is revealed in the bands as they appear.
///
/// ⚠️ WHY A CROP THAT OPENS, and not a cross-dissolve from the tile's crop to
/// the fitted composition. A dissolve between two framings of ONE picture is a
/// double exposure — every feature drawn twice at two scales, the whole window
/// long — which is precisely the defect `ZoomFlightCard
/// .holdAdoptedLiveMediaUntilLanding` records as "le média se redimensionne".
/// It would also need the picture twice, and a live clip exists once: the
/// surface the page is watching is the one flying. One picture, one geometry,
/// and no fade is the only version with nothing to hide at either end.
///
/// ⚠️ NO LAYOUT PASS PLACES THE PICTURE (the lesson #255 paid for twice). Only
/// the poses in `ZoomFlight` write `media.frame`, always inside the same
/// animation block as the window's own frame. A frame written from
/// `layoutSubviews` under a running property animator replaces the model the
/// animator's additive animations ride on, and the picture then jumps to its
/// landing position while its size is still in flight. The backdrop is a plain
/// autoresized view: it is not the picture, and it has no position of its own
/// to lose.
@MainActor
final class ZoomPageWindowCard: UIView, ZoomFlightCard {
    /// The source's own card, which draws the picture.
    let media: any ZoomFlightCard
    /// The page's shape and backdrop, fixed for the flight.
    let framing: ZoomPageFraming
    /// The page's ground — black bands, or the page's own prepared picture.
    let backdropView = UIImageView()

    init(media: any ZoomFlightCard, framing: ZoomPageFraming, frame: CGRect) {
        self.media = media
        self.framing = framing
        super.init(frame: frame)
        // Clipped and rounded: this view IS the window now, and the card
        // inside it no longer reaches the window's edges at the page end.
        clipsToBounds = true
        layer.cornerCurve = .continuous
        isUserInteractionEnabled = false
        // Black under everything, so a backdrop picture that has not been
        // decoded yet shows the band colour a landscape page shows, not a hole.
        backgroundColor = .black
        backdropView.frame = bounds
        backdropView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        backdropView.contentMode = .scaleAspectFill
        backdropView.clipsToBounds = true
        backdropView.backgroundColor = .black
        if case .picture(let image) = framing.backdrop { backdropView.image = image }
        addSubview(backdropView)
        media.autoresizingMask = []
        media.isUserInteractionEnabled = false
        media.frame = bounds
        addSubview(media)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // MARK: - ZoomFlightCard

    /// The WINDOW's corner. The picture's card is rounded separately by the
    /// poses (its resting radius at the tile end, square on the page), so a
    /// driver that rounds "the card" rounds what the viewer reads as the card.
    func setZoomCornerRadius(_ radius: CGFloat) {
        layer.cornerRadius = radius
    }

    // Everything else is the picture's answer: a driver asking the window
    // whether it is drawing, what its surface is or what radius it rests at is
    // asking about the tile it impersonates.
    var zoomLiveMediaIsDrawing: Bool { media.zoomLiveMediaIsDrawing }
    var zoomLiveMediaDebugState: String { media.zoomLiveMediaDebugState }
    var zoomCoverSurface: UIView? { media.zoomCoverSurface }
    var zoomLiveMediaContentRect: CGRect? { media.zoomLiveMediaContentRect }
    var zoomLiveMediaNativeSize: CGSize? { media.zoomLiveMediaNativeSize }
    var zoomRestingCornerRadius: CGFloat { media.zoomRestingCornerRadius }
    var zoomRestingChrome: UIView? { media.zoomRestingChrome }
    var zoomLiveMediaSurface: UIView? { media.zoomLiveMediaSurface }
    var zoomLiveMediaTracksCardBounds: Bool { media.zoomLiveMediaTracksCardBounds }
    func adoptZoomLiveMedia(_ mirror: (UIView) -> Bool) { media.adoptZoomLiveMedia(mirror) }
    func adoptZoomLiveMediaView(_ view: UIView) { media.adoptZoomLiveMediaView(view) }
    func zoomLiveMediaDidStall() { media.zoomLiveMediaDidStall() }
    func fadeInAdoptedLiveMedia(over duration: TimeInterval) { media.fadeInAdoptedLiveMedia(over: duration) }
    func holdAdoptedLiveMediaUntilLanding() { media.holdAdoptedLiveMediaUntilLanding() }
    func setZoomContentBlend(_ t: CGFloat) { media.setZoomContentBlend(t) }
    func setZoomLandingLiveMedia(_ view: UIView) { media.setZoomLandingLiveMedia(view) }
    func prepareZoomLiveMediaForFlight(destinationSize: CGSize) {
        media.prepareZoomLiveMediaForFlight(destinationSize: destinationSize)
    }
    var zoomStillMediaSurface: UIView? { media.zoomStillMediaSurface }
    var zoomStillMediaNativeSize: CGSize? { media.zoomStillMediaNativeSize }
    func prepareZoomStillMediaForFlight(destinationSize: CGSize) {
        media.prepareZoomStillMediaForFlight(destinationSize: destinationSize)
    }
    func applyZoomRestingShadow(to layer: CALayer) { media.applyZoomRestingShadow(to: layer) }
}
