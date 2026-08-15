import CoreNavigation
import MapKit
import MediaPlayback
import UIKit

/// The map side of the hero transition: the tapped pin. It can recompute its
/// own on-screen rect from the annotation's coordinate, so a dismiss returns to
/// where the pin is *now* — even after the user panned the map underneath the
/// open feed — and reports when the pin has scrolled off so the animator can
/// fall back to a centered collapse. It also builds the flying media card: a
/// `PinCardView`, the same component the pin itself renders, so the card is an
/// exact twin at the handshake instant by construction.
@MainActor
final class MapPinZoomSource: ZoomTransitionSource {
    private weak var mapView: MKMapView?
    private let annotation: any MKAnnotation
    private let thumbnail: UIImage?
    /// The face the tapped marker was wearing. A text pin has no thumbnail, so
    /// without this the flight card would take off as an empty square from a
    /// marker the viewer just saw showing a symbol.
    private let face: PinCardView.Face
    /// Mirrors the pin's live preview player onto the flight card's render
    /// surface; returns whether the pin was actually live. `nil` when the
    /// source can't be live (a cluster, or no playback coordinator).
    private let mirrorLive: ((VideoRenderView) -> Bool)?
    /// The hierarchy level the tapped marker's ring announced (a semantic
    /// cluster's city/region/country color), so the flying card takes off as
    /// the marker's exact twin — ring included. `nil` flies the neutral ring.
    private let ringKind: MapPlace.Kind?
    /// Matches the tapped marker's own geometry so the hero starts pin-sized —
    /// 56 for a media square, 44 for a text circle. Taking it from the face is
    /// what keeps the handshake exact for both: a text pin whose flight started
    /// at 56 would jump a size the instant the card replaced it.
    private var side: CGFloat { face.side }

    /// - Parameters:
    ///   - annotation: the tapped pin *or* cluster; its coordinate anchors the
    ///     hero and lets a dismiss re-find it after the map pans.
    ///   - thumbnail: the pin's cover image to fly (nil for a cluster → a plain
    ///     square).
    ///   - face: which `PinCardView` face the marker was wearing — `.text`
    ///     flies the symbol, `.media` flies `thumbnail`.
    ///   - mirrorLive: attaches the pin's live preview player to the flight
    ///     card's surface, so an animating pin flies live instead of freezing.
    init(
        mapView: MKMapView,
        annotation: any MKAnnotation,
        thumbnail: UIImage?,
        face: PinCardView.Face = .media,
        ringKind: MapPlace.Kind? = nil,
        mirrorLive: ((VideoRenderView) -> Bool)? = nil
    ) {
        self.mapView = mapView
        self.annotation = annotation
        self.thumbnail = thumbnail
        self.face = face
        self.ringKind = ringKind
        self.mirrorLive = mirrorLive
    }

    /// The flying card: the pin's exact twin — same component, same cover
    /// image and, when the pin was live-previewing, the *same player* mirrored
    /// onto the card's own render surface (two layers, one clock), so the
    /// flight carries the live video rather than a frozen copy of it.
    func makeZoomFlightCard() -> any ZoomFlightCard {
        let card = PinCardView()
        card.setFace(face)
        card.setRing(
            color: MapMarkerRing.color(for: ringKind), width: MapMarkerRing.width(for: ringKind)
        )
        card.imageView.image = thumbnail
        if let mirrorLive {
            card.adoptZoomLiveMedia { surface in
                guard let renderView = surface as? VideoRenderView else { return false }
                return mirrorLive(renderView)
            }
        }
        return card
    }

    func zoomHeroFrame(in container: UICoordinateSpace) -> CGRect {
        guard let mapView, zoomSourceIsOnScreen else {
            return ZoomTransitionGeometry.centeredFallback(in: container.bounds, side: side)
        }
        let point = mapView.convert(annotation.coordinate, toPointTo: mapView)
        let rect = CGRect(x: point.x - side / 2, y: point.y - side / 2, width: side, height: side)
        return mapView.convert(rect, to: container)
    }

    var zoomSourceIsOnScreen: Bool {
        guard let mapView else { return false }
        return mapView.visibleMapRect.contains(MKMapPoint(annotation.coordinate))
    }

    /// The map itself, not the whole screen.
    ///
    /// The depth cue is a scale about the receding view's centre, so everything
    /// inside it shrinks and drifts toward that centre. Applied to the view
    /// controller's view that took the filter bars with it — measured at 48.00pt
    /// tall dropping to 45.60 through a grab, while the app's tab bar, which
    /// lives outside the presenter, did not move at all. Half the bottom
    /// furniture receding and half of it grounded reads as a glitch, not depth.
    ///
    /// Naming the map puts the recede on the content, which is the only thing the
    /// cue is about, and leaves the bars where they were laid out. They still
    /// darken under the flight's dim — the dim covers the whole container, and
    /// opacity moves nothing.
    var zoomPresenterDepthView: UIView? { mapView }

    /// Hides the live pin while its twin is flying, and restores it when the
    /// flight is over — called by the drivers in the same transaction that
    /// installs or retires the card, so no frame can render both (or neither).
    func setZoomSourceHidden(_ hidden: Bool) {
        mapView?.view(for: annotation)?.isHidden = hidden
    }
}
