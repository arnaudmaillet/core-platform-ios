import Testing
@testable import Maps
import CoreModels

/// The semantic-cluster rules: which markers are Case B (gallery-backed
/// feed), and how the NESTED hierarchy (city ⊂ region ⊂ country) rolls up
/// as the viewer zooms out — one active depth per zoom band, lower levels
/// subsumed into their parent's marker.
struct MapSemanticClusterTests {
    private let paris = MapPlace(id: "city:paris", name: "Paris", kind: .city)
    private let versailles = MapPlace(id: "city:versailles", name: "Versailles", kind: .city)
    private let idf = MapPlace(id: "region:idf", name: "Île-de-France", kind: .region)
    private let france = MapPlace(id: "country:france", name: "France", kind: .country)

    private func pin(
        _ id: String, lat: Double = 48.85, lng: Double = 2.35, places: [MapPlace] = []
    ) -> MapPin {
        MapPin(postID: PostID(id), latitude: lat, longitude: lng,
               thumbnailURL: nil, kind: .text, places: places)
    }

    /// A full city ladder: the pin belongs to Paris, therefore to
    /// Île-de-France, therefore to France.
    private var parisLadder: [MapPlace] { [paris, idf, france] }
    private var versaillesLadder: [MapPlace] { [versailles, idf, france] }

    // MARK: - Leaf semantics (proximity clusters, Case B routing)

    /// Co-located pins cluster at any zoom; a shared LEAF place makes the
    /// group semantic and the leaf surfaces on the item.
    @Test func aFullySharedLeafMakesTheClusterSemantic() {
        let items = MapClusterEngine.cluster(
            [pin("post-1", places: parisLadder), pin("post-2", places: parisLadder)],
            zoomScale: 1, cellPoints: 64
        )
        #expect(items.count == 1)
        #expect(items[0].isSemanticCluster)
        #expect(items[0].place == paris)
    }

    @Test func oneUntaggedMemberMakesTheClusterGeneric() {
        let items = MapClusterEngine.cluster(
            [pin("post-1", places: parisLadder), pin("post-2", places: parisLadder), pin("post-3")],
            zoomScale: 1, cellPoints: 64
        )
        #expect(items.count == 1)
        #expect(!items[0].isSemanticCluster)
        #expect(items[0].place == nil)
    }

    @Test func aLonePinIsNeverASemanticCluster() {
        let items = MapClusterEngine.cluster(
            [pin("post-1", places: parisLadder)], zoomScale: 1, cellPoints: 64
        )
        #expect(items.count == 1)
        #expect(items[0].place == paris)
        #expect(!items[0].isSemanticCluster)
    }

    // MARK: - The zoom bands (one active depth each)

    @Test func eachBandActivatesExactlyOneDepth() {
        #expect(MapPlace.Kind.activeKind(atZoomLevel: 0) == .country)
        #expect(MapPlace.Kind.activeKind(atZoomLevel: 8) == .country)
        #expect(MapPlace.Kind.activeKind(atZoomLevel: 9) == .region)
        #expect(MapPlace.Kind.activeKind(atZoomLevel: 10) == .region)
        #expect(MapPlace.Kind.activeKind(atZoomLevel: 11) == .city)
        #expect(MapPlace.Kind.activeKind(atZoomLevel: 12) == .city)
        #expect(MapPlace.Kind.activeKind(atZoomLevel: 13) == nil)
        #expect(MapPlace.Kind.activeKind(atZoomLevel: 15) == nil)
    }

    // MARK: - The nested roll-up

    /// CITY band: each city masks its own posts into its own marker —
    /// two cities of one region stay two markers.
    @Test func theCityBandRendersOneMarkerPerCity() {
        let items = MapClusterEngine.cluster(
            [
                pin("post-1", lat: 48.80, lng: 2.30, places: parisLadder),
                pin("post-2", lat: 48.90, lng: 2.40, places: parisLadder),
                pin("post-3", lat: 48.70, lng: 2.20, places: versaillesLadder),
                pin("post-4", lat: 48.72, lng: 2.50, places: versaillesLadder),
            ],
            zoomScale: 1, cellPoints: 64, zoomLevel: 12
        )
        #expect(items.count == 2)
        #expect(Set(items.compactMap { $0.place?.id }) == ["city:paris", "city:versailles"])
        #expect(items.allSatisfy { $0.memberIDs.count == 2 })
    }

    /// REGION band: whole cities collapse into their parent region's ONE
    /// marker, which speaks at the region level — not any member's city.
    @Test func theRegionBandCollapsesItsCitiesIntoOneMarker() {
        let items = MapClusterEngine.cluster(
            [
                pin("post-1", lat: 48.80, lng: 2.30, places: parisLadder),
                pin("post-2", lat: 48.90, lng: 2.40, places: parisLadder),
                pin("post-3", lat: 48.70, lng: 2.20, places: versaillesLadder),
                pin("post-4", lat: 48.72, lng: 2.50, places: [idf, france]),
            ],
            zoomScale: 1, cellPoints: 64, zoomLevel: 9
        )
        #expect(items.count == 1)
        #expect(items[0].place == idf)
        #expect(items[0].memberIDs.count == 4, "both cities AND the region's own posts fold in")
    }

    /// COUNTRY band: regions collapse into the country's ONE marker; a
    /// country-only pin (no region) joins it too.
    @Test func theCountryBandCollapsesEverythingTagged() {
        let items = MapClusterEngine.cluster(
            [
                pin("post-1", lat: 48.80, lng: 2.30, places: parisLadder),
                pin("post-2", lat: 48.90, lng: 2.40, places: versaillesLadder),
                pin("post-3", lat: 48.70, lng: 2.20, places: [france]),
                pin("post-4", lat: 48.72, lng: 2.50), // untagged bystander
            ],
            zoomScale: 1, cellPoints: 64, zoomLevel: 8
        )
        let franceItem = items.first { $0.place == france }
        #expect(items.count == 2)
        #expect(franceItem?.memberIDs.count == 3)
        #expect(items.contains { $0.place == nil && $0.memberIDs == [PostID("post-4")] },
                "the bystander must not be dragged into the country's marker")
    }

    /// Past every band the hierarchy dissolves entirely: pins render
    /// through proximity alone.
    @Test func zoomingPastTheCityBandDissolvesTheHierarchy() {
        let spread = [
            pin("post-1", lat: 48.80, lng: 2.30, places: parisLadder),
            pin("post-2", lat: 48.90, lng: 2.40, places: parisLadder),
        ]
        let masked = MapClusterEngine.cluster(spread, zoomScale: 1, cellPoints: 64, zoomLevel: 12)
        let dissolved = MapClusterEngine.cluster(spread, zoomScale: 1, cellPoints: 64, zoomLevel: 13)
        #expect(masked.count == 1)
        #expect(dissolved.count == 2, "past the city band the children render independently")
        #expect(dissolved.allSatisfy { !$0.isSemanticCluster })
    }

    /// A pin whose ladder has no entry at the active depth (a region-only
    /// pin at city zoom) falls through to proximity — it is nobody's child
    /// at that depth.
    @Test func aPinWithoutTheActiveDepthFallsThroughToProximity() {
        let items = MapClusterEngine.cluster(
            [
                pin("post-1", lat: 48.80, lng: 2.30, places: [idf, france]),
                pin("post-2", lat: 48.90, lng: 2.40, places: [idf, france]),
            ],
            zoomScale: 1, cellPoints: 64, zoomLevel: 12
        )
        #expect(items.count == 2, "no city in the ladder means no city-band masking")
    }

    /// A place with ONE member at the active depth is not a parent — the
    /// pin renders as an ordinary single, because a marker wearing a place
    /// name would promise a gallery of one.
    @Test func aGroupOfOneFallsThroughToProximity() {
        let items = MapClusterEngine.cluster(
            [pin("post-1", lat: 48.80, lng: 2.30, places: parisLadder)],
            zoomScale: 1, cellPoints: 64, zoomLevel: 12
        )
        #expect(items.count == 1)
        #expect(!items[0].isCluster)
    }

    /// No zoom level (geometry-only callers, older tests) means no semantic
    /// pass at all — pure proximity.
    @Test func withoutAZoomLevelTheSemanticPassIsSkipped() {
        let items = MapClusterEngine.cluster(
            [
                pin("post-1", lat: 48.80, lng: 2.30, places: parisLadder),
                pin("post-2", lat: 48.90, lng: 2.40, places: parisLadder),
            ],
            zoomScale: 1, cellPoints: 64
        )
        #expect(items.count == 2, "far-apart pins stay apart without the pre-pass")
    }

    // MARK: - The mock zone ladders

    /// Each anchor venue (`MockGeoDiscoveryService`) carries the ladder its
    /// ring implies — city venue the full ladder, region venue two rungs,
    /// country venue one — the invariant that keeps every hierarchy level
    /// Case-B reachable in the sim.
    @Test func theVenuesAnchorTheirRungs() {
        #expect(MapMockPlaces.ladder(for: pin("p", lat: 48.8500, lng: 2.3380)).map(\.kind)
                == [.city, .region, .country])
        #expect(MapMockPlaces.ladder(for: pin("p", lat: 48.8640, lng: 2.3400)).map(\.kind)
                == [.region, .country])
        #expect(MapMockPlaces.ladder(for: pin("p", lat: 48.8480, lng: 2.3660)).map(\.kind)
                == [.country])
    }

    /// South of the country ring nothing is tagged — the corner that keeps
    /// generic pins and proximity clusters (Case A) reachable with the mock
    /// flag on.
    @Test func theScatterSouthOfTheCountryRingStaysUntagged() {
        #expect(MapMockPlaces.ladder(for: pin("p", lat: 48.7700, lng: 2.3000)).isEmpty)
    }

    /// Every ladder is leaf-first and strictly widening — the invariant the
    /// engine's depth lookup rests on.
    @Test func laddersAreLeafFirstAndNested() {
        for (lat, lng) in [(48.85, 2.33), (48.87, 2.34), (48.80, 2.45), (48.79, 2.30)] {
            let ladder = MapMockPlaces.ladder(for: pin("p", lat: lat, lng: lng))
            let depths = ladder.map(\.kind).map { kind -> Int in
                switch kind { case .city: 0; case .region: 1; case .country: 2 }
            }
            #expect(depths == depths.sorted(), "ladder must run leaf → root")
            #expect(ladder.isEmpty || ladder.last?.kind == .country,
                    "every non-empty ladder tops out at the country")
        }
    }

    // MARK: - The annotation mirror

    /// The annotation mirrors the item, and `apply` keeps it current across
    /// reconciles — a cluster that loses its shared place on a re-layout must
    /// stop being semantic on the SAME marker object.
    @Test func theClusterAnnotationTracksThePlaceAcrossApplies() {
        let semantic = MapClusterEngine.cluster(
            [pin("post-1", places: parisLadder), pin("post-2", places: parisLadder)],
            zoomScale: 1, cellPoints: 64
        )[0]
        let annotation = MapComputedCluster(semantic)
        #expect(annotation.place == paris)

        let generic = MapClusterEngine.cluster(
            [pin("post-1", places: parisLadder), pin("post-3")],
            zoomScale: 1, cellPoints: 64
        )[0]
        annotation.apply(generic)
        #expect(annotation.place == nil)
    }
}
