import Foundation

/// DEBUG stand-in for the semantic-cluster metadata the backend cannot send
/// (`dev/BACKEND_GAPS.md` §18, contract proposal in
/// `dev/issues/BACKEND_CLUSTER_TYPES.md`): under
/// `-maps-mock-semantic-clusters`, pins inside geographic ZONES of the
/// mock's Paris scatter are tagged with a nested place ladder
/// (Paris ⊂ France), so both Case-B shapes — "Paris • City Cluster" and
/// "France • Country Cluster" — are reachable in the sim, and each place
/// has spread-out children for the hierarchical masking
/// (`MapClusterEngine`'s semantic pre-pass) to absorb and release as the
/// viewer zooms. (The REGION level between them was cut from the product
/// on 2026-08-31.)
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

    /// The two nested places of the Paris scatter (see `ladder(for:)`).
    ///
    /// The MEDIA-ONLY venue anchors the City ring deliberately: a group
    /// wears its lowest-id member's face, and only a media face gets the
    /// hero presentation the gallery flow rides today. Because the city's
    /// members ride along in the roll-up, the COUNTRY marker inherits that
    /// same media face — every level of the hierarchy is Case-B reachable.
    /// Venue-only proximity clusters at the mixed and text venues still
    /// wear the TEXT face and fall back to the plain push (a documented
    /// gap until the text-cluster gallery lands).
    /// Each place carries a well-formed H3 index at the resolution its real
    /// footprint calls for — Paris ≈ res 5 (span ~17 km), France ≈ res 1
    /// (~840 km) — so the DYNAMIC banding (cell span vs viewport diagonal)
    /// governs the demo exactly as the wire will. Base cell 14 is a
    /// stand-in: the scale math never reads it, and the true Paris base
    /// cell needs the H3 kernel to compute.
    static let paris = MapPlace(
        id: "city:paris", name: "Paris", kind: .city,
        h3Index: H3CellGeometry.makeIndex(resolution: 5, baseCell: 14)
    )
    static let france = MapPlace(
        id: "country:france", name: "France", kind: .country,
        h3Index: H3CellGeometry.makeIndex(resolution: 1, baseCell: 14)
    )

    // The wider European roster (`MockGeoDiscoveryService.hierarchyAnchors`
    // seeds their members): several entities PER level, so multi-entity
    // banding is exercised at every scale. Resolutions stay uniform per
    // kind — cities res 5, countries res 1 — because the banding's span
    // table is per-KIND across the corpus; span variation across kinds
    // (17 / 840 km) is what the dynamic rule reads.
    static let lyon = MapPlace(
        id: "city:lyon", name: "Lyon", kind: .city,
        h3Index: H3CellGeometry.makeIndex(resolution: 5, baseCell: 14)
    )
    static let marseille = MapPlace(
        id: "city:marseille", name: "Marseille", kind: .city,
        h3Index: H3CellGeometry.makeIndex(resolution: 5, baseCell: 14)
    )
    static let barcelona = MapPlace(
        id: "city:barcelona", name: "Barcelona", kind: .city,
        h3Index: H3CellGeometry.makeIndex(resolution: 5, baseCell: 20)
    )
    static let spain = MapPlace(
        id: "country:spain", name: "Spain", kind: .country,
        h3Index: H3CellGeometry.makeIndex(resolution: 1, baseCell: 20)
    )
    static let germany = MapPlace(
        id: "country:germany", name: "Germany", kind: .country,
        h3Index: H3CellGeometry.makeIndex(resolution: 1, baseCell: 15)
    )

    static var isEnabled: Bool {
        ProcessInfo.processInfo.arguments.contains(launchArgument)
    }

    /// The place LADDER a pin belongs to, most specific first — genuinely
    /// NESTED zones (Paris ⊂ France), so the zoom-banded roll-up has a
    /// real hierarchy to climb: at the city band Paris masks its posts; at
    /// the country band everything tagged folds into France. Concentric
    /// over the mock's ±0.15° scatter, each ring containing its anchor
    /// venue (`MockGeoDiscoveryService`):
    ///
    /// - **France • Country**: everything north of latitude 48.780 — most
    ///   of the scatter. Anchored by the text-only venue (48.8480, 2.3660)
    ///   and — since the region level was cut (2026-08-31) — also by the
    ///   mixed venue (48.8640, 2.3400), both country-only ladders.
    /// - **Paris • City** (⊂ France): latitude in [48.800, 48.863) AND
    ///   longitude < 2.360 — anchored by the media-only venue
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
        // The historical Paris-scatter rules first, verbatim (tests pin
        // them, including the deliberately untagged southern corner): the
        // scatter box takes precedence over the country boxes below. The
        // city box is unchanged from the three-level era; the slice the
        // region used to claim now reads as country-only.
        if (48.70...49.02).contains(pin.latitude), (2.20...2.51).contains(pin.longitude) {
            guard pin.latitude >= 48.780 else { return [] }
            if pin.latitude >= 48.800, pin.latitude < 48.863, pin.longitude < 2.360 {
                return [paris, france]
            }
            return [france]
        }
        // The European roster: cities first (each inside its country), then
        // country boxes — most specific wins. (The old Provence/Catalonia
        // region boxes fell inside the France/Spain boxes, so their zones
        // degrade to country ladders with no gap.)
        if within(pin, of: (45.7640, 4.8357), radius: 0.15) { return [lyon, france] }
        if within(pin, of: (43.2965, 5.3698), radius: 0.15) { return [marseille, france] }
        if within(pin, of: (41.3874, 2.1686), radius: 0.15) { return [barcelona, spain] }
        if (42.30...51.10).contains(pin.latitude), (-5.00...8.20).contains(pin.longitude) {
            return [france]
        }
        if (36.00...43.80).contains(pin.latitude), (-9.50...3.50).contains(pin.longitude) {
            return [spain]
        }
        if (47.20...55.00).contains(pin.latitude), (5.90...15.00).contains(pin.longitude) {
            return [germany]
        }
        return []
    }

    private static func within(
        _ pin: MapPin, of anchor: (lat: Double, lng: Double), radius: Double
    ) -> Bool {
        let dLat = pin.latitude - anchor.lat
        let dLng = pin.longitude - anchor.lng
        return dLat * dLat + dLng * dLng <= radius * radius
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
