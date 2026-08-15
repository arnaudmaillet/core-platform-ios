import Foundation

/// A semantic place a pin belongs to — a city, a country, a region. This is
/// what separates a CASE-B cluster (tap → feed with a place gallery beneath)
/// from an ordinary proximity cluster (tap → feed, dismiss back to the pin).
///
/// ⚠️ MOCK-ONLY today. `geo_discovery.v1` carries no place identity of any
/// kind (`dev/BACKEND_GAPS.md` §18, spec in
/// `dev/issues/BACKEND_CLUSTER_TYPES.md`), so in production builds no pin
/// ever has one and every cluster stays generic. Under
/// `-maps-mock-semantic-clusters` (DEBUG), `MapMockPlaces` decorates the mock
/// venues with places so the whole Case-B surface is buildable and testable
/// now. When `GeoCluster` ships, this type becomes the projection of its
/// `kind`/`name`/`cluster_id` and the catalog is deleted.
public struct MapPlace: Sendable, Equatable, Hashable {
    /// Mirrors the proposed `geo_discovery.v1.ClusterKind` (city/country/
    /// region). `rawValue` is the display word the gallery title wears.
    public enum Kind: String, Sendable {
        case city = "City"
        case country = "Country"
        case region = "Region"

        /// The ONE hierarchy depth that clusters at `zoomLevel` (the
        /// viewport's 0–15 scale, `MapViewport.zoomLevel`) — the nested
        /// roll-up rule. Exactly one level of the ladder is active per band:
        /// zoomed to the city band, city clusters absorb their posts; zoom
        /// out to the region band and whole CITIES collapse into their
        /// parent region's marker; further out, regions collapse into their
        /// country; zoomed in past every band, nothing semantic renders and
        /// local proximity clustering is all there is.
        ///
        /// Client-side, mock-era banding. The contract proposal
        /// (`BACKEND_CLUSTER_TYPES.md` §C) puts this decision on the server —
        /// which sees the whole corpus — and these thresholds are deleted
        /// with the rest of the mock layer when `GeoCluster` ships. Anchors:
        /// the map opens at level 12 (0.09° span), inside the city band;
        /// `-maps-wide-region` lands at level 9 (region);
        /// `-maps-country-region` at level 8 (country).
        static func activeKind(atZoomLevel zoomLevel: Int32) -> Kind? {
            switch zoomLevel {
            case ..<9: .country
            case 9...10: .region
            case 11...12: .city
            default: nil
            }
        }
    }

    /// Stable identity ("city:paris") — what decides that two pins share a
    /// place. Opaque; mirrors the proposed `cluster_id`.
    public let id: String
    /// Display name ("Paris"). Rendered verbatim.
    public let name: String
    public let kind: Kind

    public init(id: String, name: String, kind: Kind) {
        self.id = id
        self.name = name
        self.kind = kind
    }

    /// The gallery screen's title: "Paris • City Cluster".
    public var galleryTitle: String { "\(name) • \(kind.rawValue) Cluster" }
}
