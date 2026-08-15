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

        /// Whether a place of this kind MASKS its children at `zoomLevel`
        /// (the viewport's 0–15 scale, `MapViewport.zoomLevel`): while
        /// active, every pin tagged with the place is absorbed into ONE
        /// marker regardless of screen distance, and none of its members
        /// render independently; zoomed in past the band, the group
        /// dissolves back into pins and ordinary proximity clusters.
        ///
        /// Client-side, mock-era banding. The contract proposal
        /// (`BACKEND_CLUSTER_TYPES.md` §C) puts this decision on the server —
        /// which sees the whole corpus — and these thresholds are deleted
        /// with the rest of the mock layer when `GeoCluster` ships. Anchors:
        /// the map opens at level 12 (0.09° span), where a CITY should
        /// already stand for its posts; `-maps-wide-region` lands at level 9,
        /// where a COUNTRY does.
        func masksChildren(atZoomLevel zoomLevel: Int32) -> Bool {
            switch self {
            case .city: zoomLevel <= 12
            case .region: zoomLevel <= 10
            case .country: zoomLevel <= 9
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
