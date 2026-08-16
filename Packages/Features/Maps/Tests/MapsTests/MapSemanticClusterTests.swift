import Testing
@testable import Maps
import CoreModels

/// The semantic-cluster rules: which markers are Case B (gallery-backed
/// feed), and how the NESTED hierarchy (city ⊂ region ⊂ country) renders
/// under DYNAMIC banding — each level's H3 cell span against the camera
/// viewport's diagonal, one level on screen at a time, with the zoom
/// thresholds surviving only as the H3-less fallback.
struct MapSemanticClusterTests {
    private let paris = MapPlace(
        id: "city:paris", name: "Paris", kind: .city,
        h3Index: H3CellGeometry.makeIndex(resolution: 5, baseCell: 14) // span ~17 km
    )
    private let versailles = MapPlace(
        id: "city:versailles", name: "Versailles", kind: .city,
        h3Index: H3CellGeometry.makeIndex(resolution: 5, baseCell: 14)
    )
    private let idf = MapPlace(
        id: "region:idf", name: "Île-de-France", kind: .region,
        h3Index: H3CellGeometry.makeIndex(resolution: 3, baseCell: 14) // span ~120 km
    )
    private let france = MapPlace(
        id: "country:france", name: "France", kind: .country,
        h3Index: H3CellGeometry.makeIndex(resolution: 1, baseCell: 14) // span ~840 km
    )

    /// Viewport diagonals (km) anchoring each band under the dynamic rule —
    /// the MEASURED figures the QA launch args actually produce in the sim
    /// (`-maps-banding-log`; MapKit's fitted regions are tighter than naive
    /// span math suggests).
    private let cityDiagonal = 12.9    // default region (0.09° span)
    private let regionDiagonal = 77.0  // -maps-wide-region
    private let countryDiagonal = 205.0 // -maps-country-region
    private let localDiagonal = 6.4    // -maps-tight-region

    private func pin(
        _ id: String, lat: Double = 48.85, lng: Double = 2.35, places: [MapPlace] = []
    ) -> MapPin {
        MapPin(postID: PostID(id), latitude: lat, longitude: lng,
               thumbnailURL: nil, kind: .text, places: places)
    }

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

    // MARK: - Dynamic banding (H3 cell span vs viewport diagonal)

    /// The four QA anchors, straight through the banding rule with the mock
    /// resolutions' spans.
    @Test func theViewportDiagonalSelectsTheBand() {
        let spans: [MapPlace.Kind: Double] = [.city: 17.1, .region: 119.6, .country: 837.4]
        func kind(_ diagonal: Double) -> MapPlace.Kind? {
            MapHierarchyBanding.activeKind(
                viewportDiagonalKm: diagonal, spansByKind: spans, zoomLevel: nil
            )
        }
        #expect(kind(cityDiagonal) == .city)
        #expect(kind(regionDiagonal) == .region)
        #expect(kind(countryDiagonal) == .country)
        #expect(kind(localDiagonal) == nil, "inside the city cell → local")
        #expect(kind(5000) == .country, "zoomed out past everything, the coarsest level holds")
    }

    /// The fallback ladder for an H3-less corpus: country ≤ 5, region 6–8,
    /// city 9–11, local 12+.
    @Test func theZoomFallbackBandsAnH3LessCorpus() {
        #expect(MapHierarchyBanding.fallbackKind(atZoomLevel: 0) == .country)
        #expect(MapHierarchyBanding.fallbackKind(atZoomLevel: 5) == .country)
        #expect(MapHierarchyBanding.fallbackKind(atZoomLevel: 6) == .region)
        #expect(MapHierarchyBanding.fallbackKind(atZoomLevel: 8) == .region)
        #expect(MapHierarchyBanding.fallbackKind(atZoomLevel: 9) == .city)
        #expect(MapHierarchyBanding.fallbackKind(atZoomLevel: 11) == .city)
        #expect(MapHierarchyBanding.fallbackKind(atZoomLevel: 12) == nil)
        #expect(MapHierarchyBanding.fallbackKind(atZoomLevel: 15) == nil)

        let h3Less = MapPlace(id: "city:x", name: "X", kind: .city)
        let items = MapClusterEngine.cluster(
            [
                pin("post-1", lat: 48.80, lng: 2.30, places: [h3Less]),
                pin("post-2", lat: 48.90, lng: 2.40, places: [h3Less]),
            ],
            zoomScale: 1, cellPoints: 64, zoomLevel: 10, viewportDiagonalKm: 23
        )
        #expect(items.count == 1, "no H3 anywhere → the zoom fallback grouped the city")
        #expect(items[0].isHierarchyMarker)
    }

    // MARK: - The nested roll-up, dynamically banded

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
            zoomScale: 1, cellPoints: 64, viewportDiagonalKm: cityDiagonal
        )
        #expect(items.count == 2)
        #expect(Set(items.compactMap { $0.place?.id }) == ["city:paris", "city:versailles"])
        #expect(items.allSatisfy { $0.memberIDs.count == 2 && $0.isHierarchyMarker })
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
            zoomScale: 1, cellPoints: 64, viewportDiagonalKm: regionDiagonal
        )
        #expect(items.count == 1)
        #expect(items[0].place == idf)
        #expect(items[0].memberIDs.count == 4, "both cities AND the region's own posts fold in")
    }

    /// COUNTRY band: regions collapse into the country's ONE marker, a
    /// country-only pin joins it — and an untagged bystander is HIDDEN,
    /// because a hierarchical corpus shows exactly one kind of marker.
    @Test func theCountryBandShowsTheCountryAndNothingElse() {
        let items = MapClusterEngine.cluster(
            [
                pin("post-1", lat: 48.80, lng: 2.30, places: parisLadder),
                pin("post-2", lat: 48.90, lng: 2.40, places: versaillesLadder),
                pin("post-3", lat: 48.70, lng: 2.20, places: [france]),
                pin("post-4", lat: 48.72, lng: 2.50), // untagged bystander
            ],
            zoomScale: 1, cellPoints: 64, viewportDiagonalKm: countryDiagonal
        )
        #expect(items.count == 1, "one band, one kind of marker")
        #expect(items[0].place == france)
        #expect(items[0].memberIDs.count == 3)
        #expect(!items[0].memberIDs.contains(PostID("post-4")))
    }

    /// The strict filter, dynamically: a region-only post while the city
    /// band is up belongs to a higher level and is hidden outright.
    @Test func aPinWithoutTheActiveDepthIsStrictlyHidden() {
        let items = MapClusterEngine.cluster(
            [
                pin("post-1", lat: 48.80, lng: 2.30, places: [idf, france]),
                pin("post-2", lat: 48.90, lng: 2.40, places: [idf, france]),
                pin("post-3", lat: 48.70, lng: 2.20, places: parisLadder),
                pin("post-4", lat: 48.71, lng: 2.21, places: parisLadder),
            ],
            zoomScale: 1, cellPoints: 64, viewportDiagonalKm: cityDiagonal
        )
        #expect(items.count == 1, "only the city's marker may render at the city band")
        #expect(items[0].place == paris)
        #expect(items[0].memberIDs == [PostID("post-3"), PostID("post-4")])
    }

    /// The exclusivity switch: untagged pins render through proximity when
    /// the corpus carries no hierarchy at all — production's permanent
    /// shape, which banding must never blank.
    @Test func anUnladderedCorpusKeepsProximityAtEveryViewport() {
        let scatter = [
            pin("post-1", lat: 48.80, lng: 2.30),
            pin("post-2", lat: 48.80, lng: 2.30), // co-located pair
            pin("post-3", lat: 48.95, lng: 2.45),
        ]
        for diagonal in [localDiagonal, cityDiagonal, regionDiagonal, countryDiagonal] {
            let items = MapClusterEngine.cluster(
                scatter, zoomScale: 1, cellPoints: 64,
                zoomLevel: 12, viewportDiagonalKm: diagonal
            )
            #expect(items.count == 2, "proximity layout must be untouched at \(diagonal) km")
            #expect(items.contains { $0.isCluster && $0.place == nil })
        }
    }

    // MARK: - The local band

    /// Inside the deepest cell the hierarchy stands down: spread members
    /// render as individual posts, and NOTHING on screen is a hierarchy
    /// marker.
    @Test func theLocalBandOpensTheCityIntoIndividualPosts() {
        let spread = [
            pin("post-1", lat: 48.80, lng: 2.30, places: parisLadder),
            pin("post-2", lat: 48.90, lng: 2.40, places: parisLadder),
        ]
        let city = MapClusterEngine.cluster(
            spread, zoomScale: 1, cellPoints: 64, viewportDiagonalKm: cityDiagonal
        )
        #expect(city.count == 1, "one city marker inside the band")
        #expect(city[0].isHierarchyMarker)

        let local = MapClusterEngine.cluster(
            spread, zoomScale: 1, cellPoints: 64, viewportDiagonalKm: localDiagonal
        )
        #expect(local.count == 2, "inside the city cell the members render individually")
        #expect(local.allSatisfy { !$0.isHierarchyMarker && !$0.isCluster })
    }

    /// Co-located members at the local band form an ordinary PROXIMITY
    /// cluster: it keeps its gallery tap (all members still share the leaf
    /// place) but it is NOT a hierarchy marker — its ring is neutral.
    @Test func aLocalProximityClusterIsNotAHierarchyMarker() {
        let venue = [
            pin("post-1", lat: 48.85, lng: 2.33, places: parisLadder),
            pin("post-2", lat: 48.85, lng: 2.33, places: parisLadder),
        ]
        let items = MapClusterEngine.cluster(
            venue, zoomScale: 1, cellPoints: 64, viewportDiagonalKm: localDiagonal
        )
        #expect(items.count == 1)
        #expect(items[0].isCluster)
        #expect(items[0].isSemanticCluster, "the shared leaf still routes the tap to the gallery")
        #expect(!items[0].isHierarchyMarker, "but below the city band it dresses neutral")
    }

    /// A place with ONE member at the active depth renders as a lone pin,
    /// and never merges across the band.
    @Test func aGroupOfOneRendersAloneAtItsBand() {
        let items = MapClusterEngine.cluster(
            [
                pin("post-1", lat: 48.80, lng: 2.30, places: parisLadder),
                pin("post-2", lat: 48.80, lng: 2.30), // co-located, unladdered
            ],
            zoomScale: 1, cellPoints: 64, viewportDiagonalKm: cityDiagonal
        )
        #expect(items.count == 1, "the city's lone post, and nothing else")
        #expect(!items[0].isCluster)
        #expect(items[0].memberIDs == [PostID("post-1")])
    }

    /// No banding input at all (geometry-only callers) means no semantic
    /// pass — pure proximity.
    @Test func withoutBandingInputsTheSemanticPassIsSkipped() {
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
    /// ring implies, every rung with a well-formed H3 index at its
    /// footprint's resolution.
    @Test func theVenuesAnchorTheirRungs() {
        let city = MapMockPlaces.ladder(for: pin("p", lat: 48.8500, lng: 2.3380))
        #expect(city.map(\.kind) == [.city, .region, .country])
        #expect(city.allSatisfy { place in
            place.h3Index.flatMap { H3CellGeometry(index: $0) } != nil
        })
        #expect(MapMockPlaces.ladder(for: pin("p", lat: 48.8640, lng: 2.3400)).map(\.kind)
                == [.region, .country])
        #expect(MapMockPlaces.ladder(for: pin("p", lat: 48.8480, lng: 2.3660)).map(\.kind)
                == [.country])
    }

    @Test func theScatterSouthOfTheCountryRingStaysUntagged() {
        #expect(MapMockPlaces.ladder(for: pin("p", lat: 48.7700, lng: 2.3000)).isEmpty)
    }

    /// The European roster's anchors land in their zones with the ladders
    /// their geography implies — several entities per level, mirrored from
    /// `MockGeoDiscoveryService.hierarchyAnchors`.
    @Test func theEuropeanAnchorsCarryTheirLadders() {
        #expect(MapMockPlaces.ladder(for: pin("p", lat: 45.7640, lng: 4.8357)).map(\.id)
                == ["city:lyon", "country:france"])
        #expect(MapMockPlaces.ladder(for: pin("p", lat: 43.2965, lng: 5.3698)).map(\.id)
                == ["city:marseille", "region:paca", "country:france"])
        #expect(MapMockPlaces.ladder(for: pin("p", lat: 41.3874, lng: 2.1686)).map(\.id)
                == ["city:barcelona", "region:catalonia", "country:spain"])
        #expect(MapMockPlaces.ladder(for: pin("p", lat: 43.9000, lng: 6.2000)).map(\.id)
                == ["region:paca", "country:france"])
        #expect(MapMockPlaces.ladder(for: pin("p", lat: 41.9000, lng: 1.6000)).map(\.id)
                == ["region:catalonia", "country:spain"])
        #expect(MapMockPlaces.ladder(for: pin("p", lat: 40.4200, lng: -3.7000)).map(\.id)
                == ["country:spain"])
        #expect(MapMockPlaces.ladder(for: pin("p", lat: 52.5200, lng: 13.4050)).map(\.id)
                == ["country:germany"])
    }

    /// Distinct entities of ONE level group into distinct markers — at the
    /// country band a Europe-wide corpus renders France, Spain AND Germany,
    /// each holding exactly its own posts.
    @Test func multipleCountriesRenderAsDistinctMarkers() {
        let europeDiagonal = 1500.0
        let items = MapClusterEngine.cluster(
            [
                pin("post-1", lat: 48.85, lng: 2.35, places: parisLadder),
                pin("post-2", lat: 45.76, lng: 4.84,
                    places: [MapMockPlaces.lyon, MapMockPlaces.france]),
                pin("post-3", lat: 41.39, lng: 2.17,
                    places: [MapMockPlaces.barcelona, MapMockPlaces.catalonia, MapMockPlaces.spain]),
                pin("post-4", lat: 40.42, lng: -3.70, places: [MapMockPlaces.spain]),
                pin("post-5", lat: 52.52, lng: 13.40, places: [MapMockPlaces.germany]),
                pin("post-6", lat: 52.60, lng: 13.30, places: [MapMockPlaces.germany]),
            ],
            zoomScale: 1, cellPoints: 64, viewportDiagonalKm: europeDiagonal
        )
        #expect(items.allSatisfy { $0.place?.kind == .country || !$0.isHierarchyMarker })
        let countries = items.filter { $0.isHierarchyMarker }
        #expect(Set(countries.compactMap { $0.place?.id })
                == ["country:france", "country:spain", "country:germany"])
        #expect(countries.first { $0.place?.id == "country:spain" }?.memberIDs.count == 2)
        #expect(countries.first { $0.place?.id == "country:france" }?.memberIDs.count == 2)
        #expect(countries.first { $0.place?.id == "country:germany" }?.memberIDs.count == 2)
    }

    /// Every ladder is leaf-first, strictly widening in kind AND in H3 span.
    @Test func laddersAreLeafFirstAndNested() {
        for (lat, lng) in [(48.85, 2.33), (48.87, 2.34), (48.80, 2.45), (48.79, 2.30)] {
            let ladder = MapMockPlaces.ladder(for: pin("p", lat: lat, lng: lng))
            let depths = ladder.map(\.kind).map { kind -> Int in
                switch kind { case .city: 0; case .region: 1; case .country: 2 }
            }
            #expect(depths == depths.sorted(), "ladder must run leaf → root")
            #expect(ladder.isEmpty || ladder.last?.kind == .country,
                    "every non-empty ladder tops out at the country")
            let spans = ladder.compactMap { place in
                place.h3Index.flatMap { H3CellGeometry(index: $0)?.averageSpanKm }
            }
            #expect(spans.count == ladder.count, "every rung carries a decodable cell")
            #expect(spans == spans.sorted(), "cells must widen leaf → root")
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
