import UIKit

/// The flying unit's *card* — the view that impersonates a source thumbnail at
/// one end of a hero flight and the full page at the other.
///
/// The hero machinery never names a concrete card type. Each source vends its
/// own (`ZoomTransitionSource.makeZoomFlightCard`), and it is normally the very
/// component the source renders at rest — the map's `PinCardView`, the grid's
/// tile face — which is what makes the frame-0 handshake pixel-identical by
/// construction rather than by two copies of the same radius agreeing.
///
/// Everything here is either a constant of the resting appearance or an
/// animatable channel the flight poses; nothing is transition state.
@MainActor
public protocol ZoomFlightCard: UIView {
    /// The radius the card rests at on its source (a pin's 12pt, a mosaic
    /// brick's 10pt). The flight sweeps between this and the display's own
    /// corner radius.
    var zoomRestingCornerRadius: CGFloat { get }

    /// Furniture that belongs to the card *at rest* and must not survive into
    /// the page pose — the pin's border ring, a tile's counter overlay and play
    /// badge. Faded out as the card leaves its source and back in as it
    /// returns, so a landed card never pops its furniture on.
    ///
    /// Also the insertion anchor for the destination's chrome replica, which
    /// goes *below* it: at the source end the resting chrome must read as the
    /// source's own, over everything.
    var zoomRestingChrome: UIView? { get }

    /// The surface live media renders on — non-nil only while the card is
    /// actually carrying live media. Typed as `UIView` to keep this module
    /// playback-agnostic; the card owns the concrete render type.
    var zoomLiveMediaSurface: UIView? { get }

    /// Offers the card a chance to adopt live media, by handing its own
    /// surface to `mirror` and showing it if the mirror took. Called once when
    /// the flight is built, and only when the card is not already live.
    func adoptZoomLiveMedia(_ mirror: (UIView) -> Bool)

    /// Rounds the card and any furniture that must round with it. Animatable:
    /// called inside an animation block, it sweeps.
    func setZoomCornerRadius(_ radius: CGFloat)

    /// Re-anchors the live surface for a flight. An `AVPlayerLayer` whose
    /// *bounds* animate does not track the animation smoothly — its video rect
    /// snaps — so the surface is laid out once at destination size and driven
    /// purely by a uniform-scale transform while the card's animating bounds do
    /// the crop morph.
    func prepareZoomLiveMediaForFlight(destinationSize: CGSize)

    /// Draws the card's resting drop shadow onto `layer`. The card clips, so it
    /// cannot cast one itself; the flight puts a stand-in behind it. Defaults
    /// to nothing — a mosaic brick rests flat against its neighbours, and the
    /// stand-in stays inert.
    func applyZoomRestingShadow(to layer: CALayer)
}

public extension ZoomFlightCard {
    var zoomLiveMediaSurface: UIView? { nil }
    func adoptZoomLiveMedia(_ mirror: (UIView) -> Bool) {}
    func prepareZoomLiveMediaForFlight(destinationSize: CGSize) {}
    func applyZoomRestingShadow(to layer: CALayer) {}
}
