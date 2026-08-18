import CoreContracts
import CoreModels
import CoreNetworking
import CoreNetworkingMocks
import Foundation
import Testing
@testable import Maps

/// Popularity on the map: a cluster marker wears its MOST LIKED member's
/// face (`MapClusterEngine.representative`), fed by the counter.v1 batch
/// hydration `GeoDiscoveryRepository` runs per tile query.
struct MapPlacePopularityTests {
    private let paris = MapPlace(
        id: "city:paris", name: "Paris", kind: .city,
        h3Index: H3CellGeometry.makeIndex(resolution: 5, baseCell: 14)
    )
    private let idf = MapPlace(
        id: "region:idf", name: "Île-de-France", kind: .region,
        h3Index: H3CellGeometry.makeIndex(resolution: 3, baseCell: 14)
    )
    private let france = MapPlace(
        id: "country:france", name: "France", kind: .country,
        h3Index: H3CellGeometry.makeIndex(resolution: 1, baseCell: 14)
    )

    private func pin(
        _ id: String, lat: Double = 48.85, lng: Double = 2.35,
        likes: Int64 = 0, places: [MapPlace] = []
    ) -> MapPin {
        MapPin(postID: PostID(id), latitude: lat, longitude: lng,
               thumbnailURL: nil, kind: .text, likeCount: likes, places: places)
    }

    // MARK: - The face rule

    /// A proximity cluster's face is its most liked member — and the
    /// `memberIDs` rotation still leads with the face over the full
    /// membership, so "you land on what you tapped" survives the rule.
    @Test func aProximityClusterWearsItsMostLikedFace() {
        let items = MapClusterEngine.cluster(
            [
                pin("post-1", likes: 40),
                pin("post-2", likes: 500),
                pin("post-3", likes: 12),
            ],
            zoomScale: 1, cellPoints: 64
        )
        #expect(items.count == 1)
        #expect(items[0].representative.postID == PostID("post-2"))
        #expect(items[0].memberIDs == [PostID("post-2"), PostID("post-1"), PostID("post-3")])
    }

    /// Ties fall to the lowest id — which is also what an unhydrated corpus
    /// (every count 0) degrades to, so production without counters keeps the
    /// old deterministic face instead of churning.
    @Test func aLikeTieFallsToTheLowestID() {
        let tied = MapClusterEngine.cluster(
            [pin("post-2", likes: 7), pin("post-1", likes: 7), pin("post-3", likes: 7)],
            zoomScale: 1, cellPoints: 64
        )
        #expect(tied[0].representative.postID == PostID("post-1"))

        let unhydrated = MapClusterEngine.cluster(
            [pin("post-2"), pin("post-1")], zoomScale: 1, cellPoints: 64
        )
        #expect(unhydrated[0].representative.postID == PostID("post-1"))
    }

    /// The SEMANTIC pass picks its face by the same rule: a hierarchy
    /// marker's cover is the place's most liked post, however far apart the
    /// members sit.
    @Test func aHierarchyMarkerWearsThePlacesMostLikedFace() {
        let ladder = [paris, idf, france]
        let items = MapClusterEngine.cluster(
            [
                pin("post-1", lat: 48.80, lng: 2.30, likes: 3, places: ladder),
                pin("post-2", lat: 48.90, lng: 2.40, likes: 250, places: ladder),
                pin("post-3", lat: 48.70, lng: 2.20, likes: 90, places: ladder),
            ],
            zoomScale: 1, cellPoints: 64, viewportDiagonalKm: 228.6
        )
        #expect(items.count == 1)
        #expect(items[0].isHierarchyMarker)
        #expect(items[0].representative.postID == PostID("post-2"))
        #expect(items[0].memberIDs.first == PostID("post-2"))
        #expect(Set(items[0].memberIDs) == [PostID("post-1"), PostID("post-2"), PostID("post-3")])
    }

    // MARK: - The counter hydration

    /// The pure stamping rule: known ids take their count, unknown ids keep 0.
    @Test func stampingMapsKnownIDsAndLeavesUnknownAtZero() {
        let stamped = GeoDiscoveryRepository.stamped(
            [pin("post-1"), pin("post-2")],
            likesByPostID: ["post-1": 123]
        )
        #expect(stamped.map(\.likeCount) == [123, 0])
        #expect(stamped.map(\.postID) == [PostID("post-1"), PostID("post-2")])
    }

    /// End to end over the production wire shape — repository → generated
    /// clients → MockBFF → geo + counter mocks sharing one store: every pin
    /// arrives wearing exactly the LIKE count the counter mock seeds, which
    /// is the same store the gallery's hydration reads, so the pin face and
    /// the gallery's first tile agree by construction.
    @Test func queryTileHydratesEveryPinWithItsSeededLikeCount() async throws {
        let dataset = MockSocialDataset()
        let store = MockCounterStore(dataset: dataset)
        let bff = MockBFF()
        MockGeoDiscoveryService(dataset: dataset).register(on: bff)
        MockCounterService(store: store).register(on: bff)
        let client = ConnectClientFactory.makeUnauthenticated(
            host: "https://mock.bff.local", httpClient: bff
        )
        let repository = GeoDiscoveryRepository(
            geoClient: GeoDiscovery_V1_GeoDiscoveryServiceClient(client: client),
            counterClient: Counter_V1_CounterServiceClient(client: client)
        )

        let viewport = MapViewport.make(
            centerLat: 48.8566, centerLng: 2.3522, latitudeSpan: 0.6, longitudeSpan: 0.6
        )
        let pins = try await repository.queryTile(viewport).pins
        #expect(!pins.isEmpty)
        #expect(pins.allSatisfy { $0.likeCount == store.likeCount(for: $0.postID.rawValue) })
        #expect(pins.contains { $0.likeCount > 0 }, "the seed is varied — an all-zero read is a broken hydration")
    }

    /// No counter client (tests, a future surface) stays the pre-popularity
    /// repository: pins arrive, at likeCount 0.
    @Test func withoutACounterClientPinsArriveUnstamped() async throws {
        let bff = MockBFF()
        MockGeoDiscoveryService(dataset: MockSocialDataset()).register(on: bff)
        let client = ConnectClientFactory.makeUnauthenticated(
            host: "https://mock.bff.local", httpClient: bff
        )
        let repository = GeoDiscoveryRepository(
            geoClient: GeoDiscovery_V1_GeoDiscoveryServiceClient(client: client)
        )
        let viewport = MapViewport.make(
            centerLat: 48.8566, centerLng: 2.3522, latitudeSpan: 0.6, longitudeSpan: 0.6
        )
        let pins = try await repository.queryTile(viewport).pins
        #expect(!pins.isEmpty)
        #expect(pins.allSatisfy { $0.likeCount == 0 })
    }
}
