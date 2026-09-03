import FeedInterface
import MapKit
import UIKit

/// The map side of the text reveal: a marker's disc, described as something a
/// window can open out of.
///
/// The counterpart of `MapPinZoomSource`, and deliberately its shape — same
/// coordinate-anchored rect, so a dismissal returns to where the marker is
/// *now* even after the viewer panned the map under the open post, and the same
/// honest answer (`nil`) when it has scrolled off, which sends the window to a
/// centred fallback rather than to a stale rect.
///
/// What differs is what flies. A hero carries the marker's PHOTOGRAPH into a
/// page that shows the same photograph; there is no such continuity for a text
/// post, whose page has no glyph and no tinted disc anywhere on it. So nothing
/// is carried: the real page is installed at full size, the disc is the hole it
/// is seen through, and the marker's own content is drawn fresh into that hole
/// and handed over — glyph first, then the tint it sits on, by which time the
/// page underneath is already wearing the same colour.
@MainActor
enum MapPinRevealSource {
    /// Everything the reveal needs to open a marker, in the one place both the
    /// rect and the shape are read — a rect measured for a 44pt disc and a
    /// radius taken from a 56pt square would describe two different markers.
    ///
    /// - Parameters:
    ///   - concealMarker: hides the marker for as long as its window is in the
    ///     air. A grab moves that window off the disc, and a disc left in place
    ///     is a second copy of the thing the viewer believes they are holding.
    ///   - depthView: what the depth cue recedes — the map and its bars, never
    ///     the app's own chrome around them.
    static func origin(
        mapView: MKMapView,
        annotation: any MKAnnotation,
        face: PinCardView.Face,
        ringKind: MapPlace.Kind?,
        concealMarker: @escaping (Bool) -> Void,
        depthView: @escaping () -> UIView?,
        dismissalDidEnd: @escaping (Bool) -> Void = { _ in }
    ) -> TextRevealOrigin {
        let side = face.side
        var origin = TextRevealOrigin(
            rowFrame: { [weak mapView] space in
                // ⚠️ STILL HELD, not merely still in the viewport. A reconcile
                // that ran while the feed was open can remove this annotation
                // and leave its COORDINATE exactly where it was — the rect test
                // alone then reports a marker that is not there, and the window
                // closes onto empty map while the concealment silently no-ops
                // on a view that no longer exists. `MapPinZoomSource` states
                // the same rule for the same reason. Nil sends the close to the
                // centred fallback, which is honest.
                guard let mapView,
                      mapView.annotations.contains(where: {
                          ($0 as AnyObject) === (annotation as AnyObject)
                      }),
                      mapView.visibleMapRect.contains(MKMapPoint(annotation.coordinate))
                else { return nil }
                let point = mapView.convert(annotation.coordinate, toPointTo: mapView)
                let rect = CGRect(
                    x: point.x - side / 2, y: point.y - side / 2, width: side, height: side
                )
                return mapView.convert(rect, to: space)
            },
            // No cut. The veil exists so a window shows no more of the page
            // than a truncated CARD shows of the post; a disc shows none of it,
            // so there is nothing to hold back — the stand-in covers the page
            // until the page is what the viewer should be looking at.
            captionEnd: nil,
            depthView: depthView,
            // ⚠️ THE PAGE TRAVELS WHOLE, and this note is the third answer
            // to one question — both earlier ones are kept because each was
            // wrong in a way the next could only be found by living through.
            //
            // FIRST: nothing is carried, the window simply clips the live page.
            // Filmed as the departure content "truncating in the transition
            // window" — a disc is not a card, and clipping a full screen down
            // to 44pt is a keyhole onto one corner of it.
            //
            // SECOND: the stand-in carries a COPY of the page's media, scaled
            // uniformly so it shrinks whole. That fixed the truncation and
            // introduced its own: a viewer playing with the grab saw the media
            // anchored in the window while the post — caption, band, comment
            // stream — faded away over it. A copy of the media is not the post.
            //
            // THIRD, and this one: the page itself is scaled to COVER the
            // window (`RevealStage.pageCovering`), so the whole post travels,
            // live, with its video still playing because it is the page's own
            // surface and a transform leaves bounds alone. Nothing is copied,
            // so nothing can disagree with the original. The stand-in goes back
            // to being what it always was on the opening leg — the marker's
            // face, and only that.
            // ⚠️ THE FACE IS READ AT ASK TIME, like the rect above it. The
            // marker's avatar may still have been loading when this origin was
            // built, and a stand-in that captured the answer then would fly the
            // FALLBACK GLYPH while the map behind it shows the author — which
            // is exactly what was filmed: a transition carrying an icon the
            // viewer never saw on the pin.
            makeDismissStandIn: { [weak mapView] _ in
                marker(face: face, ringKind: ringKind, avatar: mapView?.wornAvatar(for: annotation))
            },
            makePresentStandIn: { [weak mapView] in
                marker(face: face, ringKind: ringKind, avatar: mapView?.wornAvatar(for: annotation))
            },
            // Nothing to align to. The page holds still and the window opens
            // over it — see `TextRevealOrigin.alignsPageToSource`.
            alignsPageToSource: false,
            pageFit: .covering,
            cornerRadius: face.cornerRadius,
            fill: PinCardView.textRevealGround,
            setConcealed: concealMarker,
            dismissalDidEnd: dismissalDidEnd
        )
        // ⚠️ A MARKER'S ARRIVAL IS A PICTURE, so it comes up while the finger
        // is still down.
        //
        // The default holds it back until the release, and that default was
        // measured on a CARD arrival: text laid out for a width the window had
        // not reached, clipped at its edge. A disc has no layout to be wrong
        // about — and held back it meant the window carried the page all the
        // way down and the face turned up once the flight was over. Filmed as
        // "the destination is not in the transition window".
        origin.arrivalRisesUnderFinger = true
        return origin
    }

    /// The marker, drawn fresh — the same component the map itself renders, so
    /// the window is the disc's twin at the handshake by construction rather
    /// than by two places agreeing on a radius and a tint.
    ///
    /// `departure` is the picture the window is closing OVER, when there is one.
    /// The card fades its whole face — disc AND glyph, one opaque unit — in over
    /// it, which keeps this a dissolve between two finished drawings rather than
    /// two half-drawn ones.
    private static func marker(
        face: PinCardView.Face, ringKind: MapPlace.Kind?, avatar: UIImage? = nil
    ) -> UIView {
        let card = PinCardView(frame: CGRect(x: 0, y: 0, width: face.side, height: face.side))
        card.setFace(face)
        card.setTextAvatar(avatar)
        card.setRing(
            color: MapMarkerRing.color(for: ringKind), width: MapMarkerRing.width(for: ringKind)
        )
        card.isUserInteractionEnabled = false
        return card
    }
}

extension MKMapView {
    /// The author face the marker for `annotation` is currently wearing.
    ///
    /// Asked of the VIEW rather than of the model, and asked late, because that
    /// is the picture on screen: the pin loads its avatar asynchronously, so the
    /// model can know a URL while the marker is still showing the fallback, and
    /// a transition must carry whichever of the two the viewer is looking at.
    func wornAvatar(for annotation: any MKAnnotation) -> UIImage? {
        switch view(for: annotation) {
        case let pin as MapAnnotationView: pin.card.textAvatar
        case let cluster as MapClusterAnnotationView: cluster.card.textAvatar
        default: nil
        }
    }
}
