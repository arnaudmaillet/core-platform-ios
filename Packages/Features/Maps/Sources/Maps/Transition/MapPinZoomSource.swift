import CoreNavigation
import MapKit
import UIKit

/// The map side of the hero transition: the tapped pin. It can recompute its
/// own on-screen rect from the annotation's coordinate, so a dismiss returns to
/// where the pin is *now* — even after the user panned the map underneath the
/// open feed — and reports when the pin has scrolled off so the animator can
/// fall back to a centered collapse.
@MainActor
final class MapPinZoomSource: ZoomTransitionSource {
    private weak var mapView: MKMapView?
    private let annotation: any MKAnnotation
    private let thumbnail: UIImage?
    /// Matches `MapAnnotationView`'s square so the hero starts pin-sized.
    private let side: CGFloat = 56

    /// - Parameters:
    ///   - annotation: the tapped pin *or* cluster; its coordinate anchors the
    ///     hero and lets a dismiss re-find it after the map pans.
    ///   - thumbnail: the pin's cover image to fly (nil for a cluster → a plain
    ///     square).
    init(mapView: MKMapView, annotation: any MKAnnotation, thumbnail: UIImage?) {
        self.mapView = mapView
        self.annotation = annotation
        self.thumbnail = thumbnail
    }

    func zoomHeroSnapshot() -> UIView? {
        let imageView = UIImageView(image: thumbnail)
        imageView.contentMode = .scaleAspectFill
        imageView.clipsToBounds = true
        imageView.backgroundColor = .secondarySystemBackground
        imageView.layer.cornerRadius = 12
        imageView.layer.cornerCurve = .continuous
        return imageView
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

    func zoomSourceDidReturn() {
        mapView?.view(for: annotation)?.isHidden = false
    }

    /// Hides the live pin while its snapshot is flying, so there's no duplicate.
    func hideSourcePin() {
        mapView?.view(for: annotation)?.isHidden = true
    }
}
