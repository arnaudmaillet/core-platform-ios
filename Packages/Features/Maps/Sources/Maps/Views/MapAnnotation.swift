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

    /// The city or country this lone pin speaks for when it is a band's
    /// group of one (`MapClusterEngine.Item.hierarchyPlace`) — so it wears
    /// its place's dress AND opens its place page, like a band cluster — or
    /// nil for an ordinary local pin. Set by the map's reconcile on every
    /// layout.
    ///
    /// ⚠️ THE PLACE, NOT ONLY ITS KIND. This used to carry the kind alone,
    /// which was enough to dress the marker and not enough to route it: the
    /// tap had no place to build a page for, so a one-post country opened as
    /// a plain single and its vertical dismissal landed on the MAP.
    var hierarchyPlace: MapPlace?

    /// The depth this pin's dress speaks for — see `hierarchyPlace`.
    var hierarchyKind: MapPlace.Kind? { hierarchyPlace?.kind }

    init(pin: MapPin, hierarchyPlace: MapPlace? = nil) {
        self.pin = pin
        self.hierarchyPlace = hierarchyPlace
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
