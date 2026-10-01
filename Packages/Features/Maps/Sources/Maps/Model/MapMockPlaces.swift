import CoreLocation
import Foundation

/// DEBUG stand-in for the semantic-cluster metadata the backend cannot send
/// (`dev/BACKEND_GAPS.md` §18, contract proposal in
/// `dev/issues/BACKEND_CLUSTER_TYPES.md`): pins inside geographic ZONES of
/// the mock's Paris scatter are tagged with a nested place ladder
/// (Paris ⊂ France), so both Case-B shapes — "Paris • City Cluster" and
/// "France • Country Cluster" — are reachable in the sim, and each place
/// has spread-out children for the hierarchical masking
/// (`MapClusterEngine`'s semantic pre-pass) to absorb and release as the
/// viewer zooms. (The REGION level between them was cut from the product
/// on 2026-08-31.)
///
/// The DEFAULT mock experience since 2026-08-31 — no launch argument
/// required. Whether the decoration runs is the COMPOSITION ROOT's call
/// (`AppContainer.seedsMapPlaces`, mock mode only, opt out with
/// `-maps-mock-no-places`), threaded through `MapsFeatureBuilder` into the
/// view model; this catalog itself is a pure mapping, so tests reach for
/// `ladder(for:)`/`decorate` without any ambient state deciding for them.
///
/// Keyed on COORDINATES, deliberately: post ids shift with seeding,
/// geography is the zones' identity. The anchor values mirror the mock
/// service's venue constants — the spec's mock-parity section ties the two
/// files together, and when `GeoCluster` ships this catalog is deleted.
///
/// The whole type is DEBUG-only so no production build can grow a code path
/// that manufactures place identity the wire never asserted.
#if DEBUG
enum MapMockPlaces {

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
    // Each place's RANK is fictional (product ask, 25 September 2026: "fait
    // un rank fictif dans le mock") — no wire carries one; see
    // `MapPlace.rank`. Paris is #3 of the cities, as the ask put it.
    static let paris = MapPlace(
        id: "city:paris", name: "Paris", kind: .city,
        h3Index: H3CellGeometry.makeIndex(resolution: 5, baseCell: 14),
        rank: 3
    )
    static let france = MapPlace(
        id: "country:france", name: "France", kind: .country,
        h3Index: H3CellGeometry.makeIndex(resolution: 1, baseCell: 14),
        rank: 2
    )

    // The wider European roster (`MockGeoDiscoveryService.hierarchyAnchors`
    // seeds their members): several entities PER level, so multi-entity
    // banding is exercised at every scale. Resolutions stay uniform per
    // kind — cities res 5, countries res 1 — because the banding's span
    // table is per-KIND across the corpus; span variation across kinds
    // (17 / 840 km) is what the dynamic rule reads.
    static let lyon = MapPlace(
        id: "city:lyon", name: "Lyon", kind: .city,
        h3Index: H3CellGeometry.makeIndex(resolution: 5, baseCell: 14),
        rank: 9
    )
    static let marseille = MapPlace(
        id: "city:marseille", name: "Marseille", kind: .city,
        h3Index: H3CellGeometry.makeIndex(resolution: 5, baseCell: 14),
        rank: 12
    )
    static let barcelona = MapPlace(
        id: "city:barcelona", name: "Barcelona", kind: .city,
        h3Index: H3CellGeometry.makeIndex(resolution: 5, baseCell: 20),
        rank: 2
    )
    static let madrid = MapPlace(
        id: "city:madrid", name: "Madrid", kind: .city,
        h3Index: H3CellGeometry.makeIndex(resolution: 5, baseCell: 20),
        rank: 5
    )
    static let berlin = MapPlace(
        id: "city:berlin", name: "Berlin", kind: .city,
        h3Index: H3CellGeometry.makeIndex(resolution: 5, baseCell: 15),
        rank: 6
    )
    static let rome = MapPlace(
        id: "city:rome", name: "Rome", kind: .city,
        h3Index: H3CellGeometry.makeIndex(resolution: 5, baseCell: 21),
        rank: 4
    )
    static let london = MapPlace(
        id: "city:london", name: "London", kind: .city,
        h3Index: H3CellGeometry.makeIndex(resolution: 5, baseCell: 25),
        rank: 1
    )
    static let spain = MapPlace(
        id: "country:spain", name: "Spain", kind: .country,
        h3Index: H3CellGeometry.makeIndex(resolution: 1, baseCell: 20),
        rank: 4
    )
    static let germany = MapPlace(
        id: "country:germany", name: "Germany", kind: .country,
        h3Index: H3CellGeometry.makeIndex(resolution: 1, baseCell: 15),
        rank: 5
    )
    static let italy = MapPlace(
        id: "country:italy", name: "Italy", kind: .country,
        h3Index: H3CellGeometry.makeIndex(resolution: 1, baseCell: 21),
        rank: 3
    )
    static let unitedKingdom = MapPlace(
        id: "country:uk", name: "United Kingdom", kind: .country,
        h3Index: H3CellGeometry.makeIndex(resolution: 1, baseCell: 25),
        rank: 1
    )

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
        // degrade to country ladders with no gap.) City circle centers
        // mirror `MockGeoDiscoveryService.hierarchyAnchors` verbatim — the
        // mock-parity contract.
        if within(pin, of: (45.7640, 4.8357), radius: 0.15) { return [lyon, france] }
        if within(pin, of: (43.2965, 5.3698), radius: 0.15) { return [marseille, france] }
        if within(pin, of: (41.3874, 2.1686), radius: 0.15) { return [barcelona, spain] }
        if within(pin, of: (40.4200, -3.7000), radius: 0.15) { return [madrid, spain] }
        if within(pin, of: (52.5200, 13.4050), radius: 0.15) { return [berlin, germany] }
        if within(pin, of: (41.8933, 12.4829), radius: 0.15) { return [rome, italy] }
        if within(pin, of: (51.5074, -0.1278), radius: 0.15) { return [london, unitedKingdom] }
        // Country boxes, France FIRST on purpose: it wins its Alps overlap
        // with Italy and its Channel overlap with the UK box the same way it
        // already wins Alsace against Germany — no seeds sit in any of the
        // contested strips.
        if (42.30...51.10).contains(pin.latitude), (-5.00...8.20).contains(pin.longitude) {
            return [france]
        }
        if (36.00...43.80).contains(pin.latitude), (-9.50...3.50).contains(pin.longitude) {
            return [spain]
        }
        if (47.20...55.00).contains(pin.latitude), (5.90...15.00).contains(pin.longitude) {
            return [germany]
        }
        if (36.60...47.10).contains(pin.latitude), (6.60...18.60).contains(pin.longitude) {
            return [italy]
        }
        if (49.90...58.70).contains(pin.latitude), (-8.20...1.80).contains(pin.longitude) {
            return [unitedKingdom]
        }
        // The world beyond Europe (`MockWorldSeed`): its city circles, then
        // the country's real BORDER rather than a box — the Americas'
        // rectangles would overlap (Montreal sits inside any box that holds
        // New York's latitude), and the border is what the map unlocks by
        // anyway (`CountryAtlas`). Only these few countries are tested, each
        // behind its bounds check, so the cost is a handful of comparisons.
        for circle in worldCities where within(pin, of: circle.center, radius: 0.15) {
            return [circle.city, circle.country]
        }
        let coordinate = CLLocationCoordinate2D(latitude: pin.latitude, longitude: pin.longitude)
        for entry in worldCountries
        where CountryAtlas.shared.country(code: entry.code)?.contains(coordinate) == true {
            return [entry.place]
        }
        return []
    }

    // MARK: - The world beyond Europe

    // Cities res 5 and countries res 1 like the European roster (the
    // banding's span table is per KIND). Base cells are stand-ins, as above.
    // Ranks are fictional, continuing the European ones.
    static let milan = MapPlace(
        id: "city:milan", name: "Milan", kind: .city,
        h3Index: H3CellGeometry.makeIndex(resolution: 5, baseCell: 21), rank: 19
    )
    static let newYork = MapPlace(
        id: "city:new-york", name: "New York", kind: .city,
        h3Index: H3CellGeometry.makeIndex(resolution: 5, baseCell: 30), rank: 7
    )
    static let losAngeles = MapPlace(
        id: "city:los-angeles", name: "Los Angeles", kind: .city,
        h3Index: H3CellGeometry.makeIndex(resolution: 5, baseCell: 30), rank: 15
    )
    static let tokyo = MapPlace(
        id: "city:tokyo", name: "Tokyo", kind: .city,
        h3Index: H3CellGeometry.makeIndex(resolution: 5, baseCell: 40), rank: 8
    )
    static let kyoto = MapPlace(
        id: "city:kyoto", name: "Kyoto", kind: .city,
        h3Index: H3CellGeometry.makeIndex(resolution: 5, baseCell: 40), rank: 18
    )
    static let rioDeJaneiro = MapPlace(
        id: "city:rio-de-janeiro", name: "Rio de Janeiro", kind: .city,
        h3Index: H3CellGeometry.makeIndex(resolution: 5, baseCell: 80), rank: 11
    )
    static let marrakech = MapPlace(
        id: "city:marrakech", name: "Marrakech", kind: .city,
        h3Index: H3CellGeometry.makeIndex(resolution: 5, baseCell: 50), rank: 16
    )
    static let sydney = MapPlace(
        id: "city:sydney", name: "Sydney", kind: .city,
        h3Index: H3CellGeometry.makeIndex(resolution: 5, baseCell: 110), rank: 13
    )
    static let montreal = MapPlace(
        id: "city:montreal", name: "Montreal", kind: .city,
        h3Index: H3CellGeometry.makeIndex(resolution: 5, baseCell: 16), rank: 17
    )
    static let mexicoCity = MapPlace(
        id: "city:mexico-city", name: "Mexico City", kind: .city,
        h3Index: H3CellGeometry.makeIndex(resolution: 5, baseCell: 60), rank: 14
    )
    static let seoul = MapPlace(
        id: "city:seoul", name: "Seoul", kind: .city,
        h3Index: H3CellGeometry.makeIndex(resolution: 5, baseCell: 41), rank: 10
    )
    static let unitedStates = MapPlace(
        id: "country:us", name: "United States", kind: .country,
        h3Index: H3CellGeometry.makeIndex(resolution: 1, baseCell: 30), rank: 6
    )
    static let japan = MapPlace(
        id: "country:japan", name: "Japan", kind: .country,
        h3Index: H3CellGeometry.makeIndex(resolution: 1, baseCell: 40), rank: 7
    )
    static let brazil = MapPlace(
        id: "country:brazil", name: "Brazil", kind: .country,
        h3Index: H3CellGeometry.makeIndex(resolution: 1, baseCell: 80), rank: 9
    )
    static let morocco = MapPlace(
        id: "country:morocco", name: "Morocco", kind: .country,
        h3Index: H3CellGeometry.makeIndex(resolution: 1, baseCell: 50), rank: 13
    )
    static let australia = MapPlace(
        id: "country:australia", name: "Australia", kind: .country,
        h3Index: H3CellGeometry.makeIndex(resolution: 1, baseCell: 110), rank: 10
    )
    static let canada = MapPlace(
        id: "country:canada", name: "Canada", kind: .country,
        h3Index: H3CellGeometry.makeIndex(resolution: 1, baseCell: 16), rank: 12
    )
    static let mexico = MapPlace(
        id: "country:mexico", name: "Mexico", kind: .country,
        h3Index: H3CellGeometry.makeIndex(resolution: 1, baseCell: 60), rank: 11
    )
    static let southKorea = MapPlace(
        id: "country:south-korea", name: "South Korea", kind: .country,
        h3Index: H3CellGeometry.makeIndex(resolution: 1, baseCell: 41), rank: 8
    )

    /// The world seed's city circles. Centers mirror `MockWorldSeed`'s
    /// cities verbatim — the mock-parity contract,
    /// `MockWorldSeedParityTests`. (Barcelona, Madrid, Rome, London and
    /// Berlin are already the European roster's circles above.)
    static let worldCities: [(center: (lat: Double, lng: Double), city: MapPlace, country: MapPlace)] = [
        ((45.4642, 9.1900), milan, italy),
        ((40.7128, -74.0060), newYork, unitedStates),
        ((34.0522, -118.2437), losAngeles, unitedStates),
        ((35.6762, 139.6503), tokyo, japan),
        ((35.0116, 135.7681), kyoto, japan),
        ((-22.9068, -43.1729), rioDeJaneiro, brazil),
        ((31.6295, -7.9811), marrakech, morocco),
        ((-33.8688, 151.2093), sydney, australia),
        ((45.5019, -73.5674), montreal, canada),
        ((19.4326, -99.1332), mexicoCity, mexico),
        ((37.5665, 126.9780), seoul, southKorea)
    ]

    /// The world seed's countries outside the European boxes, by the ISO
    /// code `CountryAtlas` keys their border with.
    static let worldCountries: [(code: String, place: MapPlace)] = [
        ("US", unitedStates), ("CA", canada), ("MX", mexico), ("BR", brazil),
        ("MA", morocco), ("JP", japan), ("KR", southKorea), ("AU", australia)
    ]

    private static func within(
        _ pin: MapPin, of anchor: (lat: Double, lng: Double), radius: Double
    ) -> Bool {
        let dLat = pin.latitude - anchor.lat
        let dLng = pin.longitude - anchor.lng
        return dLat * dLat + dLng * dLng <= radius * radius
    }

    /// Tags every pin with its zone ladder. PURE — whether it runs at all is
    /// the composition root's decision, not ambient state read here.
    static func decorate(_ pins: [MapPin]) -> [MapPin] {
        pins.map { pin in
            let ladder = ladder(for: pin)
            return ladder.isEmpty ? pin : pin.tagged(with: ladder)
        }
    }
}
#endif
