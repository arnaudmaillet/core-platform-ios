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

        /// The ONE hierarchy depth rendered at `zoomLevel` (the viewport's
        /// 0–15 scale, `MapViewport.zoomLevel`) — STRICT banding: every
        /// semantic band has exactly one active level, hierarchy members
        /// render ONLY through that level's markers, and members whose
        /// ladder has no rung at the active depth are hidden outright
        /// rather than mixed in. Country ≤ 8, region 9–10, city 11–12 —
        /// and `nil` from 13 up: the LOCAL band, where the city cluster
        /// opens and the whole hierarchy stands down in favour of
        /// individual posts and ordinary generic proximity clusters.
        ///
        /// Client-side, mock-era banding. The contract proposal
        /// (`BACKEND_CLUSTER_TYPES.md` §C) puts this decision on the server —
        /// which sees the whole corpus — and these thresholds are deleted
        /// with the rest of the mock layer when `GeoCluster` ships. Anchors:
        /// the map opens at level 12 (0.09° span), inside the city band;
        /// `-maps-wide-region` lands at level 9 (region);
        /// `-maps-country-region` at level 8 (country);
        /// `-maps-tight-region` at level 13 (local).
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
