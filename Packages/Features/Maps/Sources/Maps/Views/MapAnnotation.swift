import CoreLocation
import MapKit

/// The `MKAnnotation` wrapper around a `MapPin`. Identity is the `post_id`, so
/// MapKit (and our own `[PostID: MapAnnotation]` bookkeeping) treats the same
/// post as one stable marker across viewport updates — the key to touching only
/// changed pins instead of rebuilding the whole set on every pan.
final class MapAnnotation: NSObject, MKAnnotation {
    /// KVO-observed by MapKit so an in-place coordinate change moves the marker
    /// without a remove/add cycle.
    @objc dynamic var coordinate: CLLocationCoordinate2D

    private(set) var pin: MapPin

    /// Collapses overlapping / co-located markers into a cluster bubble. This is
    /// visual de-densification of the *returned* pins (honest given the server's
    /// Top-K), not a claim about true world density.
    static let clusteringIdentifier = "post-pin"

    init(pin: MapPin) {
        self.pin = pin
        self.coordinate = CLLocationCoordinate2D(latitude: pin.latitude, longitude: pin.longitude)
        super.init()
    }

    /// Applies a content change for the same post id (moved coordinate / new
    /// thumbnail / media kind). The marker instance is kept; its view refreshes.
    func update(pin: MapPin) {
        self.pin = pin
        let next = CLLocationCoordinate2D(latitude: pin.latitude, longitude: pin.longitude)
        if next.latitude != coordinate.latitude || next.longitude != coordinate.longitude {
            coordinate = next
        }
    }

    override func isEqual(_ object: Any?) -> Bool {
        (object as? MapAnnotation)?.pin.postID == pin.postID
    }

    override var hash: Int { pin.postID.hashValue }
}
