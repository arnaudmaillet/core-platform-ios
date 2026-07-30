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
    /// Mirrors the pin's live preview player onto the flight card's render
    /// surface; returns whether the pin was actually live. `nil` when the
    /// source can't be live (a cluster, or no playback coordinator).
    private let mirrorLive: ((VideoRenderView) -> Bool)?
    /// Matches `MapAnnotationView`'s square so the hero starts pin-sized.
    private let side: CGFloat = MapAnnotationView.side

    /// - Parameters:
    ///   - annotation: the tapped pin *or* cluster; its coordinate anchors the
    ///     hero and lets a dismiss re-find it after the map pans.
    ///   - thumbnail: the pin's cover image to fly (nil for a cluster → a plain
    ///     square).
    ///   - mirrorLive: attaches the pin's live preview player to the flight
    ///     card's surface, so an animating pin flies live instead of freezing.
    init(
        mapView: MKMapView,
        annotation: any MKAnnotation,
        thumbnail: UIImage?,
        mirrorLive: ((VideoRenderView) -> Bool)? = nil
    ) {
        self.mapView = mapView
        self.annotation = annotation
        self.thumbnail = thumbnail
        self.mirrorLive = mirrorLive
    }

    /// The flying card: the pin's exact twin — same component, same cover
    /// image and, when the pin was live-previewing, the *same player* mirrored
    /// onto the card's own render surface (two layers, one clock), so the
    /// flight carries the live video rather than a frozen copy of it.
    func makeZoomFlightCard() -> any ZoomFlightCard {
        let card = PinCardView()
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

    /// Hides the live pin while its twin is flying, and restores it when the
    /// flight is over — called by the drivers in the same transaction that
    /// installs or retires the card, so no frame can render both (or neither).
    func setZoomSourceHidden(_ hidden: Bool) {
        mapView?.view(for: annotation)?.isHidden = hidden
    }
}
