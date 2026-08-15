import Foundation

/// DEBUG stand-in for the semantic-cluster metadata the backend cannot send
/// (`dev/BACKEND_GAPS.md` §18, contract proposal in
/// `dev/issues/BACKEND_CLUSTER_TYPES.md`): under
/// `-maps-mock-semantic-clusters`, pins inside three geographic ZONES of the
/// mock's Paris scatter are tagged with a place, one zone per
/// `MapPlace.Kind`, so every Case-B shape — "Paris • City Cluster",
/// "France • Country Cluster", "Île-de-France • Region Cluster" — is
/// reachable in the sim, and each place has spread-out children for the
/// hierarchical masking (`MapClusterEngine`'s semantic pre-pass) to absorb
/// and release as the viewer zooms.
///
/// Keyed on COORDINATES, deliberately: post ids shift with seeding,
/// geography is the zones' identity. The anchor values mirror the mock
/// service's venue constants — the spec's mock-parity section ties the two
/// files together, and when `GeoCluster` ships both this catalog and the
/// launch argument are deleted.
///
/// The whole type is DEBUG-only so no production build can grow a code path
/// that manufactures place identity the wire never asserted.
#if DEBUG
enum MapMockPlaces {
    static let launchArgument = "-maps-mock-semantic-clusters"

    /// The three places, one per `MapPlace.Kind`, nested by their ladders
    /// (see `ladder(for:)`).
    ///
    /// The MEDIA-ONLY venue anchors the City ring deliberately: a group
    /// wears its lowest-id member's face, and only a media face gets the
    /// hero presentation the gallery flow rides today. Because the city's
    /// members ride along in every roll-up, the REGION and COUNTRY markers
    /// inherit that same media face — every level of the hierarchy is
    /// Case-B reachable. Venue-only proximity clusters at the mixed and
    /// text venues still wear the TEXT face and fall back to the plain
    /// push (a documented gap until the text-cluster gallery lands).
    /// Each place carries a well-formed H3 index at the resolution its real
    /// footprint calls for — Paris ≈ res 5 (span ~17 km), Île-de-France ≈
    /// res 3 (~120 km), France ≈ res 1 (~840 km) — so the DYNAMIC banding
    /// (cell span vs viewport diagonal) governs the demo exactly as the wire
    /// will. Base cell 14 is a stand-in: the scale math never reads it, and
    /// the true Paris base cell needs the H3 kernel to compute.
    static let paris = MapPlace(
        id: "city:paris", name: "Paris", kind: .city,
        h3Index: H3CellGeometry.makeIndex(resolution: 5, baseCell: 14)
    )
    static let france = MapPlace(
        id: "country:france", name: "France", kind: .country,
        h3Index: H3CellGeometry.makeIndex(resolution: 1, baseCell: 14)
    )
    static let ileDeFrance = MapPlace(
        id: "region:idf", name: "Île-de-France", kind: .region,
        h3Index: H3CellGeometry.makeIndex(resolution: 3, baseCell: 14)
    )

    static var isEnabled: Bool {
        ProcessInfo.processInfo.arguments.contains(launchArgument)
    }

    /// The place LADDER a pin belongs to, most specific first — genuinely
    /// NESTED zones (Paris ⊂ Île-de-France ⊂ France), so the zoom-banded
    /// roll-up has a real hierarchy to climb: at the city band Paris masks
    /// its posts; at the region band the whole city collapses into
    /// Île-de-France's marker together with the region's other posts; at
    /// the country band everything tagged folds into France. Concentric
    /// over the mock's ±0.15° scatter, each ring containing its anchor
    /// venue (`MockGeoDiscoveryService`):
    ///
    /// - **France • Country**: everything north of latitude 48.780 — most
    ///   of the scatter. Anchored by the text-only venue (48.8480, 2.3660),
    ///   which sits in no region, so it also demonstrates a country-only
    ///   ladder.
    /// - **Île-de-France • Region** (⊂ France): latitude ≥ 48.800 AND
    ///   longitude < 2.360. Anchored by the mixed venue (48.8640, 2.3400),
    ///   which sits in no city.
    /// - **Paris • City** (⊂ Île-de-France): the region's slice below
    ///   latitude 48.863 — anchored by the media-only venue
    ///   (48.8500, 2.3380), with the scattered pins of the opening
    ///   viewport's lower half, which is what makes the city mask legible
    ///   at launch.
    ///
    /// South of 48.780 stays UNTAGGED — which, under exclusive banding,
    /// means those pins never render while the flag is ON (a hierarchical
    /// corpus shows one level per band, nothing else). They exist to pin
    /// that exclusivity in tests; generic pins and proximity clusters
    /// (Case A) are exercised with the flag OFF, where no pin carries a
    /// ladder and the map is the ordinary proximity playground.
    static func ladder(for pin: MapPin) -> [MapPlace] {
        guard pin.latitude >= 48.780 else { return [] }
        guard pin.latitude >= 48.800, pin.longitude < 2.360 else { return [france] }
        guard pin.latitude < 48.863 else { return [ileDeFrance, france] }
        return [paris, ileDeFrance, france]
    }

    /// Tags every pin with its zone ladder. A no-op (identity, not even a
    /// copy) when the launch argument is absent.
    static func decorate(_ pins: [MapPin]) -> [MapPin] {
        guard isEnabled else { return pins }
        return pins.map { pin in
            let ladder = ladder(for: pin)
            return ladder.isEmpty ? pin : pin.tagged(with: ladder)
        }
    }
}
#endif
