import UIKit

/// The flying unit for a LETTERBOXED destination: a page-shaped, unclipped box
/// that carries the source's own card at the picture's rect inside it, and the
/// page chrome replica over the whole box.
///
/// ⚠️ WHY A BOX AROUND THE CARD, rather than the card flown to the media rect
/// with its chrome inside it. Every card clips (`clipsToBounds`), because the
/// clip IS the crop morph. A chrome replica inside a card sized to a
/// letterboxed picture is cut off at the bands — and the page's real chrome is
/// not: a caption over the bottom band would be missing for the whole flight
/// and pop in at the landing. Hosting the chrome as a loose SIBLING of the card
/// was the other option, and it would have had to follow the card through
/// every channel anybody drives: the grab's live centre, the dip's spring, the
/// mid-air catch's transform, the grab's deformation, the landing cover's
/// re-parenting, and each of the half-dozen teardowns that remove the card.
/// Missing one is a caption left hanging on screen. Inside one box, every one
/// of those drivers moves both by construction, because they only ever touch
/// THIS view.
///
/// The box is the PAGE: its frame is the page rect at the page end, and the
/// tile grown by the bands at the tile end
/// (`ZoomTransitionGeometry.letterboxCardFrame`). The picture inside it is
/// always the same fraction of it, so the inner card's aspect-fill is exactly
/// the page's aspect-fit at one end and exactly the tile's crop at the other.
///
/// Every `ZoomFlightCard` member forwards to the inner card, so a driver that
/// asks the box anything — is it drawing, what is its surface, what radius does
/// it rest at — gets the picture's answer. `ZoomFlight` poses the inner card
/// directly (`mediaCard`); the drivers never need to know there are two.
@MainActor
final class ZoomLetterboxCard: UIView, ZoomFlightCard {
    /// The source's own card, which draws the picture.
    let media: any ZoomFlightCard
    /// The destination's page and the picture inside it, in the container's
    /// space — fixed at build, since the mapping between them is a ratio that
    /// holds at every size the box is posed at.
    let page: CGRect
    let mediaRect: CGRect

    init(media: any ZoomFlightCard, page: CGRect, mediaRect: CGRect) {
        self.media = media
        self.page = page
        self.mediaRect = mediaRect
        super.init(frame: page)
        // UNCLIPPED: the chrome replica reaches into the bands, and the bands
        // are this box's whole reason to exist. Clear: the dim behind the
        // flight is what paints them black, on the flight's own curve.
        clipsToBounds = false
        backgroundColor = .clear
        isUserInteractionEnabled = false
        media.autoresizingMask = []
        addSubview(media)
        media.frame = mediaFrame(inCardOfSize: page.size)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Where the picture sits inside the box when the box is `size`.
    func mediaFrame(inCardOfSize size: CGSize) -> CGRect {
        ZoomTransitionGeometry.letterboxMediaFrame(inCardOfSize: size, page: page, media: mediaRect)
    }

    /// The box that puts the picture at `rect`.
    func cardFrame(forMedia rect: CGRect) -> CGRect {
        ZoomTransitionGeometry.letterboxCardFrame(forMedia: rect, page: page, media: mediaRect)
    }

    // ⚠️ NO LAYOUT PASS PLACES THE PICTURE — only the poses do, and there is
    // deliberately no `layoutSubviews` here re-deriving it from the box.
    //
    // It existed, as a "backstop" for drivers that resize the box directly,
    // and it broke two flights by writing a frame OUTSIDE an animation block
    // under a running property animator. That replaces the model the
    // animator's additive animations ride on, and the position channel goes
    // with it:
    //
    // - on the tap-back, the pose's `landing - box.origin` and this pass's
    //   proportional rect differed in the last bit, and the picture presented
    //   at its LANDING centre from the first frame while its size was still
    //   page-sized — filmed as the video jumping to the top-left of a card
    //   whose chrome had not moved;
    // - on a caught-and-reversed present, UIKit re-bases the picture's model
    //   when the interruptor scrubs, a layout pass then saw 83pt of "drift",
    //   "fixed" it, and the reversal landed 45pt right and 84pt low of the
    //   tile it had left from (the flag-off flight lands exactly).
    //
    // Nothing needs it. Every pose places the picture through
    // `mediaFrame(inCardOfSize:)` in the same block as the box, the grab's dip
    // hand-over is followed by `poseFloating` in the same turn, and the
    // landing cover is re-framed onto the page it is already posed for.

    /// The box parked over the landed page as its cover.
    ///
    /// ⚠️ OPAQUE, because the page under a parked cover is already revealed:
    /// its own chrome comes back while the cover is still up
    /// (`zoomTransitionDidEnd`), and through clear bands it would draw a second
    /// copy of the caption under the replica's. Black is what the flight's dim
    /// was painting there a frame earlier and what the fitted page paints
    /// there a frame later, so it is not a change anyone can see.
    func becomeLandingCover() {
        backgroundColor = .black
    }

    // MARK: - ZoomFlightCard, forwarded to the picture

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
    func fadeInAdoptedLiveMedia(over duration: TimeInterval) { media.fadeInAdoptedLiveMedia(over: duration) }
    func holdAdoptedLiveMediaUntilLanding() { media.holdAdoptedLiveMediaUntilLanding() }
    func setZoomCornerRadius(_ radius: CGFloat) { media.setZoomCornerRadius(radius) }
    func setZoomContentBlend(_ t: CGFloat) { media.setZoomContentBlend(t) }
    func setZoomLandingLiveMedia(_ view: UIView) { media.setZoomLandingLiveMedia(view) }
    func prepareZoomLiveMediaForFlight(destinationSize: CGSize) {
        media.prepareZoomLiveMediaForFlight(destinationSize: destinationSize)
    }
    func applyZoomRestingShadow(to layer: CALayer) { media.applyZoomRestingShadow(to: layer) }
}
