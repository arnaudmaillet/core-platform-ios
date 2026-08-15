import Testing
@testable import Maps
import CoreModels

/// The place rule that decides Case B (gallery-backed feed) vs Case A (plain
/// hero back to the pin): a cluster is SEMANTIC only when every member claims
/// the same place, and a lone pin never is, whatever it is tagged with.
struct MapSemanticClusterTests {
    private let paris = MapPlace(id: "city:paris", name: "Paris", kind: .city)
    private let france = MapPlace(id: "country:france", name: "France", kind: .country)

    private func pin(_ id: String, lat: Double = 48.85, lng: Double = 2.35, place: MapPlace? = nil) -> MapPin {
        MapPin(postID: PostID(id), latitude: lat, longitude: lng,
               thumbnailURL: nil, kind: .text, place: place)
    }

    /// Co-located pins cluster at any zoom; a shared place makes the group
    /// semantic and the place surfaces on the item.
    @Test func aFullySharedPlaceMakesTheClusterSemantic() {
        let items = MapClusterEngine.cluster(
            [pin("post-1", place: paris), pin("post-2", place: paris)],
            zoomScale: 1, cellPoints: 64
        )
        #expect(items.count == 1)
        #expect(items[0].isSemanticCluster)
        #expect(items[0].place == paris)
    }

    /// One untagged member — a scattered pin that drifted into the venue's
    /// cell — makes the group generic: a gallery titled "Paris" must not open
    /// over posts that never claimed Paris.
    @Test func oneUntaggedMemberMakesTheClusterGeneric() {
        let items = MapClusterEngine.cluster(
            [pin("post-1", place: paris), pin("post-2", place: paris), pin("post-3")],
            zoomScale: 1, cellPoints: 64
        )
        #expect(items.count == 1)
        #expect(items[0].isCluster)
        #expect(!items[0].isSemanticCluster)
        #expect(items[0].place == nil)
    }

    @Test func mixedPlacesMakeTheClusterGeneric() {
        let items = MapClusterEngine.cluster(
            [pin("post-1", place: paris), pin("post-2", place: france)],
            zoomScale: 1, cellPoints: 64
        )
        #expect(items.count == 1)
        #expect(!items[0].isSemanticCluster)
    }

    /// A lone pin carries its tag as data but is never a semantic CLUSTER —
    /// Case A whatever it is tagged with.
    @Test func aLonePinIsNeverASemanticCluster() {
        let items = MapClusterEngine.cluster(
            [pin("post-1", place: paris)], zoomScale: 1, cellPoints: 64
        )
        #expect(items.count == 1)
        #expect(items[0].place == paris)
        #expect(!items[0].isSemanticCluster)
    }

    // MARK: - Hierarchical masking (the semantic pre-pass)

    /// The map-rendering rule: while a place's band is active, EVERY pin
    /// tagged with it folds into one marker, however far apart on screen —
    /// the parent pin replaces its children at that zoom.
    @Test func anActiveBandMasksSpreadOutChildrenIntoOneMarker() {
        let items = MapClusterEngine.cluster(
            [
                pin("post-1", lat: 48.80, lng: 2.30, place: paris),
                pin("post-2", lat: 48.90, lng: 2.40, place: paris), // far away on screen
                pin("post-3", lat: 48.70, lng: 2.20),               // untagged bystander
            ],
            zoomScale: 1, cellPoints: 64, zoomLevel: 12
        )
        let parisItem = items.first { $0.place == paris }
        #expect(items.count == 2)
        #expect(parisItem?.isSemanticCluster == true)
        #expect(parisItem?.memberIDs.count == 2)
        #expect(items.contains { $0.place == nil && $0.memberIDs == [PostID("post-3")] },
                "the bystander must not be dragged into the place's marker")
    }

    /// Zooming in past the band dissolves the parent back into ordinary
    /// pins/proximity clusters — the break-down half of the rule.
    @Test func zoomingPastTheBandDissolvesTheParent() {
        let spread = [
            pin("post-1", lat: 48.80, lng: 2.30, place: paris),
            pin("post-2", lat: 48.90, lng: 2.40, place: paris),
        ]
        let masked = MapClusterEngine.cluster(spread, zoomScale: 1, cellPoints: 64, zoomLevel: 12)
        let dissolved = MapClusterEngine.cluster(spread, zoomScale: 1, cellPoints: 64, zoomLevel: 13)
        #expect(masked.count == 1)
        #expect(dissolved.count == 2, "past the city band the children render independently")
        #expect(dissolved.allSatisfy { !$0.isSemanticCluster })
    }

    /// Each kind has its own band: at level 10 a region masks but a country
    /// (band ≤ 9) does not yet.
    @Test func bandsAreOrderedByKind() {
        #expect(MapPlace.Kind.city.masksChildren(atZoomLevel: 12))
        #expect(!MapPlace.Kind.city.masksChildren(atZoomLevel: 13))
        #expect(MapPlace.Kind.region.masksChildren(atZoomLevel: 10))
        #expect(!MapPlace.Kind.region.masksChildren(atZoomLevel: 11))
        #expect(MapPlace.Kind.country.masksChildren(atZoomLevel: 9))
        #expect(!MapPlace.Kind.country.masksChildren(atZoomLevel: 10))
    }

    /// Two different places never share a marker, active bands or not.
    @Test func distinctPlacesMaskIntoDistinctMarkers() {
        let items = MapClusterEngine.cluster(
            [
                pin("post-1", lat: 48.80, lng: 2.30, place: paris),
                pin("post-2", lat: 48.90, lng: 2.40, place: paris),
                pin("post-3", lat: 48.95, lng: 2.45, place: france),
                pin("post-4", lat: 48.99, lng: 2.49, place: france),
            ],
            zoomScale: 1, cellPoints: 64, zoomLevel: 9
        )
        #expect(items.count == 2)
        #expect(Set(items.compactMap { $0.place?.id }) == ["city:paris", "country:france"])
    }

    /// A place with ONE tagged pin is not a parent — the pin renders as an
    /// ordinary single (carrying its tag as data), because a marker wearing
    /// a place name would promise a gallery of one.
    @Test func aGroupOfOneFallsThroughToProximity() {
        let items = MapClusterEngine.cluster(
            [pin("post-1", lat: 48.80, lng: 2.30, place: paris)],
            zoomScale: 1, cellPoints: 64, zoomLevel: 12
        )
        #expect(items.count == 1)
        #expect(!items[0].isCluster)
        #expect(items[0].place == paris)
    }

    /// No zoom level (geometry-only callers, older tests) means no semantic
    /// pass at all — pure proximity, place surfacing only via shared tags.
    @Test func withoutAZoomLevelTheSemanticPassIsSkipped() {
        let items = MapClusterEngine.cluster(
            [
                pin("post-1", lat: 48.80, lng: 2.30, place: paris),
                pin("post-2", lat: 48.90, lng: 2.40, place: paris),
            ],
            zoomScale: 1, cellPoints: 64
        )
        #expect(items.count == 2, "far-apart pins stay apart without the pre-pass")
    }

    // MARK: - The mock zones

    /// Each anchor venue (`MockGeoDiscoveryService`) sits inside its own
    /// place's zone — the invariant that keeps every Case-B shape reachable
    /// in the sim — and the zones are checked in an order that keeps them
    /// disjoint.
    @Test func theVenuesAnchorTheirZones() {
        #expect(MapMockPlaces.place(for: pin("p", lat: 48.8500, lng: 2.3380))?.kind == .city)
        #expect(MapMockPlaces.place(for: pin("p", lat: 48.8640, lng: 2.3400))?.kind == .country)
        #expect(MapMockPlaces.place(for: pin("p", lat: 48.8480, lng: 2.3660))?.kind == .region)
    }

    /// South of the city band nothing is tagged — the corner that keeps
    /// generic pins and proximity clusters (Case A) reachable with the
    /// mock flag on.
    @Test func theScatterSouthOfTheCityBandStaysUntagged() {
        #expect(MapMockPlaces.place(for: pin("p", lat: 48.7900, lng: 2.3000)) == nil)
    }

    /// The zones tile without double-claims: the country line wins over the
    /// region line, which wins over the city band.
    @Test func theZonesAreCheckedInPrecedenceOrder() {
        #expect(MapMockPlaces.place(for: pin("p", lat: 48.9000, lng: 2.4500))?.kind == .country)
        #expect(MapMockPlaces.place(for: pin("p", lat: 48.8500, lng: 2.4500))?.kind == .region)
        #expect(MapMockPlaces.place(for: pin("p", lat: 48.8560, lng: 2.3440))?.kind == .city)
    }

    /// The annotation mirrors the item, and `apply` keeps it current across
    /// reconciles — a cluster that loses its shared place on a re-layout must
    /// stop being semantic on the SAME marker object.
    @Test func theClusterAnnotationTracksThePlaceAcrossApplies() {
        let semantic = MapClusterEngine.cluster(
            [pin("post-1", place: paris), pin("post-2", place: paris)],
            zoomScale: 1, cellPoints: 64
        )[0]
        let annotation = MapComputedCluster(semantic)
        #expect(annotation.place == paris)

        let generic = MapClusterEngine.cluster(
            [pin("post-1", place: paris), pin("post-3")],
            zoomScale: 1, cellPoints: 64
        )[0]
        annotation.apply(generic)
        #expect(annotation.place == nil)
    }
}
