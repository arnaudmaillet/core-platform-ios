import FeedInterface
import Foundation

/// A semantic place a pin belongs to — a city or a country. The active
/// band's marker for one of these (a HIERARCHY marker) is a Case-B cluster:
/// tap → feed with the place's page beneath. Every other marker — proximity
/// clusters included, even leaf-sharing ones — keeps the plain feed and
/// dismisses back to the pin.
///
/// ⚠️ MOCK-ONLY today. `geo_discovery.v1` carries no place identity of any
/// kind (`dev/BACKEND_GAPS.md` §18, spec in
/// `dev/issues/BACKEND_CLUSTER_TYPES.md`), so on the fleet no pin ever has
/// one and every cluster stays generic. In DEBUG mock mode `MapMockPlaces`
/// decorates the pins with places BY DEFAULT (the composition root's
/// `seedsMapPlaces`; opt out with `-maps-mock-no-places`), so the whole
/// Case-B surface is buildable and testable now. When `GeoCluster` ships,
/// this type becomes the projection of its `kind`/`name`/`cluster_id` and
/// the catalog is deleted.
public struct MapPlace: Sendable, Equatable, Hashable {
    /// Mirrors the proposed `geo_discovery.v1.ClusterKind` (city/country —
    /// the proposal's REGION level was cut from the product on 2026-08-31,
    /// so a wire value outside these two is dropped at the projection).
    /// `rawValue` is the display word the gallery title wears.
    public enum Kind: String, Sendable {
        case city = "City"
        case country = "Country"

        // Which depth renders at a given camera is `MapHierarchyBanding`'s
        // question now — dynamic from H3 cell spans, with a zoom fallback.
    }

    /// Stable identity ("city:paris") — what decides that two pins share a
    /// place. Opaque; mirrors the proposed `cluster_id`.
    public let id: String
    /// Display name ("Paris"). Rendered verbatim.
    public let name: String
    public let kind: Kind
    /// The H3 cell this place aggregates over (mode-1 index; see
    /// `H3CellGeometry`), or `nil` when the wire hasn't said — the cell's
    /// span is what the DYNAMIC banding compares against the viewport, and
    /// its region is what a camera fit targets. Mock-filled today
    /// (`dev/issues/BACKEND_H3_BOUNDING_BOX.md`).
    public let h3Index: UInt64?
    /// Where the place stands among places of its kind, 1-based — MOCK-FILLED
    /// (`MapMockPlaces`); no wire carries a rank yet, so it is nil on the
    /// fleet and the page draws no rank column.
    public let rank: Int?

    public init(id: String, name: String, kind: Kind, h3Index: UInt64? = nil, rank: Int? = nil) {
        self.id = id
        self.name = name
        self.kind = kind
        self.h3Index = h3Index
        self.rank = rank
    }

    /// "#3 City Rank", as the page's first counter — nil without a rank.
    public var rankBadge: PlaceRankBadge? {
        rank.map { PlaceRankBadge(position: $0, label: "\(kind.rawValue) Rank") }
    }

    /// The gallery screen's title: "Paris • City Cluster".
    public var galleryTitle: String { "\(name) • \(kind.rawValue) Cluster" }
}
