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
    /// Whether the card's live media is putting pixels on screen right now.
    ///
    /// Distinct from `zoomLiveMediaSurface != nil`, which only says the card
    /// HAS one. A card can be present, parented and fully opaque while its live
    /// surface has quietly stopped drawing — and because the card's cover image
    /// sits directly beneath that surface, the cover is then what the viewer
    /// sees. That is a thumbnail pop with every other signal reading healthy,
    /// which is the state this exists to make observable.
    ///
    /// Defaults to `true`: a card with no live media has only its cover, which
    /// is always drawing, so there is nothing that can stop.
    var zoomLiveMediaIsDrawing: Bool { get }

    /// The live surface's full state, for tracing. Empty when there is none.
    /// CoreNavigation cannot ask a `VideoRenderView` anything directly — it
    /// deliberately does not depend on MediaPlayback — so the card reports it.
    var zoomLiveMediaDebugState: String { get }

    /// The media's NATIVE aspect, if known.
    ///
    /// The flight lays its surface out at this aspect rather than at the
    /// destination viewport's, because a viewport-sized surface is ALREADY a
    /// crop: the page renders `resizeAspectFill`, so scaling that down to a
    /// tile crops a second time, from the page's crop rather than from the
    /// media. The landing tile renders aspect-fill of the NATIVE media, so the
    /// two disagree and the difference shows as a snap at the landing.
    ///
    /// With the surface at native aspect, scaling it to cover either endpoint
    /// reproduces that endpoint's own aspect-fill exactly, and the card's
    /// animating bounds are the only crop in play.
    ///
    /// Nil falls back to the viewport, which is the previous behaviour.
    var zoomLiveMediaNativeSize: CGSize? { get }

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

    /// Whether that furniture fades out as the card becomes the page.
    ///
    /// True for a card whose furniture belongs to its SOURCE — a grid brick's
    /// counters and play badge are the grid's, and leaving them lit over a
    /// full-screen page would be furniture the page never had.
    ///
    /// False when the card has nothing else to carry. A text card's furniture
    /// IS the post: its caption, which the destination also shows. Fading it
    /// emptied the card at full screen and left a blank window before the page
    /// arrived — visible in the first crossfade prototype as one clear frame of
    /// nothing between the morph and the comments.
    var zoomRestingChromeFadesOut: Bool { get }


    /// The surface live media renders on — non-nil only while the card is
    /// actually carrying live media. Typed as `UIView` to keep this module
    /// playback-agnostic; the card owns the concrete render type.
    var zoomLiveMediaSurface: UIView? { get }

    /// Offers the card a chance to adopt live media, by handing its own
    /// surface to `mirror` and showing it if the mirror took. Called once when
    /// the flight is built, and only when the card is not already live.
    func adoptZoomLiveMedia(_ mirror: (UIView) -> Bool)

    /// Takes ownership of a media view that is ALREADY rendering, in place of
    /// the card's own surface.
    ///
    /// Preferred over `adoptZoomLiveMedia`, and the difference is visible: a
    /// mirror is a second `AVPlayerLayer`, which carries no decoded frame and
    /// reports `isReadyForDisplay == false` for ~70-100ms while the other side
    /// is already hidden — the flash at the start of the flight. Moving a view
    /// that is mid-playback has no such window. Typed loosely to keep this
    /// module playback-agnostic; cards downcast and ignore what they do not
    /// recognise.
    func adoptZoomLiveMediaView(_ view: UIView)

    /// When true the card sizes its own live surface to its bounds, and the
    /// flight leaves the surface's transform alone.
    ///
    /// The alternative — a surface laid out at PAGE size and driven by a
    /// uniform scale — always renders the page's crop, whatever shape the card
    /// currently is. Measured against a 402x874 page: a 2:1 landscape brick
    /// shows only 22.9% of that surface vertically, so takeoff jumps from the
    /// tile's wide aspect-fill to a thin band of a page-shaped video. A 1:2
    /// portrait brick shows 92.3% and looks fine, which is exactly why the
    /// artifact reads as "landscape only".
    ///
    /// Tracking the card's bounds lets `resizeAspectFill` recompute the crop at
    /// every instant, so the morph is continuous at any aspect. Default false
    /// keeps the uniform-scale behaviour for cards that rely on it.
    var zoomLiveMediaTracksCardBounds: Bool { get }

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
    /// Fading out is the norm — most source furniture is its source's own.
    var zoomRestingChromeFadesOut: Bool { true }
    var zoomLiveMediaIsDrawing: Bool { true }
    var zoomLiveMediaDebugState: String { "" }
    var zoomLiveMediaNativeSize: CGSize? { nil }
    var zoomLiveMediaSurface: UIView? { nil }
    func adoptZoomLiveMedia(_ mirror: (UIView) -> Bool) {}
    func adoptZoomLiveMediaView(_ view: UIView) {}
    var zoomLiveMediaTracksCardBounds: Bool { false }
    func prepareZoomLiveMediaForFlight(destinationSize: CGSize) {}
    func applyZoomRestingShadow(to layer: CALayer) {}
}
