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
        return TextRevealOrigin(
            rowFrame: { [weak mapView] space in
                guard let mapView,
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
            // ⚠️ THE STAND-IN CARRIES THE DEPARTING PICTURE, and the reasoning
            // that once said it need not is recorded here because it was wrong
            // in an instructive way.
            //
            // "A window's departure operand is the LIVE PAGE it is closing
            // over" is true about IDENTITY and false about BEHAVIOUR. A reveal
            // window CLIPS that page: as the mask shrinks toward a 44pt disc
            // the viewer sees less and less of it, and then a beat of empty
            // fill before the disc arrives. Filmed — a photograph truncating
            // into a blank rounded rect, reported as "the departure content
            // gets truncated in the transition window".
            //
            // A copy inside the stand-in SCALES instead, because the card owns
            // it: the media stays whole and shrinks with the window, which is
            // what the flight home to a media marker already does and what this
            // was asked to match. The page underneath is covered by the
            // stand-in, so nothing is drawn twice.
            makeDismissStandIn: { settlement in
                marker(face: face, ringKind: ringKind, departure: settlement.still)
            },
            makePresentStandIn: { marker(face: face, ringKind: ringKind) },
            // Nothing to align to. The page holds still and the window opens
            // over it — see `TextRevealOrigin.alignsPageToSource`.
            alignsPageToSource: false,
            cornerRadius: face.cornerRadius,
            fill: PinCardView.textRevealGround,
            setConcealed: concealMarker,
            dismissalDidEnd: dismissalDidEnd
        )
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
        face: PinCardView.Face, ringKind: MapPlace.Kind?, departure: UIImage? = nil
    ) -> UIView {
        let card = PinCardView(frame: CGRect(x: 0, y: 0, width: face.side, height: face.side))
        card.setFace(face)
        card.setRing(
            color: MapMarkerRing.color(for: ringKind), width: MapMarkerRing.width(for: ringKind)
        )
        card.setDeparturePicture(departure)
        card.isUserInteractionEnabled = false
        return card
    }
}
