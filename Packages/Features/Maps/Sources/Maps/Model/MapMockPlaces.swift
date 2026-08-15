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

    /// The three places, one per `MapPlace.Kind`.
    ///
    /// The assignment is deliberate: the MEDIA-ONLY venue anchors the
    /// flagship City case, because a venue's cluster wears its lowest-id
    /// member's face and only a media face gets the hero presentation the
    /// gallery flow rides today — the mixed and text venues' groups wear
    /// the TEXT face (their lowest ids are text posts) and still fall back
    /// to the plain push (a documented gap until the text-cluster gallery
    /// lands).
    static let paris = MapPlace(id: "city:paris", name: "Paris", kind: .city)
    static let france = MapPlace(id: "country:france", name: "France", kind: .country)
    static let ileDeFrance = MapPlace(id: "region:idf", name: "Île-de-France", kind: .region)

    static var isEnabled: Bool {
        ProcessInfo.processInfo.arguments.contains(launchArgument)
    }

    /// The place a pin belongs to — ZONES, not exact venue coordinates, so
    /// each place has genuinely SPREAD-OUT children for the hierarchical
    /// masking to absorb (a place with one coordinate masks nothing anyone
    /// can see). Three disjoint zones tiling most of the mock's ±0.15°
    /// Paris scatter, each containing its anchor venue
    /// (`MockGeoDiscoveryService`), each big enough that its collapse is
    /// unmistakable at the zoom that activates it:
    ///
    /// - **France • Country**: everything north of latitude 48.863 —
    ///   including the mixed venue (48.8640, 2.3400) and roughly half the
    ///   scatter.
    /// - **Île-de-France • Region**: east of longitude 2.360, below the
    ///   country line — including the text-only venue (48.8480, 2.3660).
    /// - **Paris • City**: the remaining band down to latitude 48.800 —
    ///   including the media-only venue (48.8500, 2.3380) and the handful
    ///   of scattered pins visible in the opening viewport's lower half,
    ///   which is what makes the city mask legible at launch.
    ///
    /// South of 48.800 stays UNTAGGED, so generic pins and proximity
    /// clusters (Case A) remain reachable with the flag on. Checked in
    /// this order, the zones are disjoint by construction. True NESTING
    /// (Paris inside Île-de-France inside France) needs one pin to carry
    /// several places at once, which is the server's aggregation to express
    /// (`BACKEND_CLUSTER_TYPES.md`); the mock trades it for disjoint zones.
    static func place(for pin: MapPin) -> MapPlace? {
        if pin.latitude >= 48.863 { return france }
        if pin.longitude >= 2.360 { return ileDeFrance }
        if pin.latitude >= 48.800 { return paris }
        return nil
    }

    /// Tags every pin in a place's zone. A no-op (identity, not even a
    /// copy) when the launch argument is absent.
    static func decorate(_ pins: [MapPin]) -> [MapPin] {
        guard isEnabled else { return pins }
        return pins.map { pin in
            guard let place = place(for: pin) else { return pin }
            return pin.tagged(with: place)
        }
    }
}
#endif
