import CoreContracts
import CoreModels
import CoreNetworking
import CoreNetworkingMocks
import Foundation
import Testing
@testable import Maps

/// Drives the read path — repository → generated client → real ProtocolClient
/// → MockBFF — with production wire bytes, in-process.
struct GeoDiscoveryRepositoryTests {
    private func makeRepository(
        handler: @escaping @Sendable (GeoDiscovery_V1_QueryTileRequest) -> GeoDiscovery_V1_QueryTileResponse
    ) -> GeoDiscoveryRepository {
        let bff = MockBFF()
        bff.register(path: "/geo_discovery.v1.GeoDiscoveryService/QueryTile") { (request: GeoDiscovery_V1_QueryTileRequest) in
            .success(handler(request))
        }
        let client = ConnectClientFactory.makeUnauthenticated(host: "https://mock.bff.local", httpClient: bff)
        return GeoDiscoveryRepository(geoClient: GeoDiscovery_V1_GeoDiscoveryServiceClient(client: client))
    }

    private func radarPin(_ id: String, lat: Double, lng: Double, thumb: String) -> GeoDiscovery_V1_RadarPin {
        var pin = GeoDiscovery_V1_RadarPin()
        pin.postID = id
        pin.lat = lat
        pin.lng = lng
        pin.thumbnailURL = thumb
        return pin
    }

    @Test func mapsRadarPinsToMapPins() async throws {
        let repository = makeRepository { _ in
            var response = GeoDiscovery_V1_QueryTileResponse()
            response.tileCount = 3
            response.pins = [
                self.radarPin("post-1", lat: 48.857, lng: 2.342, thumb: "mock://media/1"),
                self.radarPin("post-2", lat: 48.855, lng: 2.346, thumb: "mock://media/2")
            ]
            return response
        }

        let result = try await repository.queryTile(.make(
            centerLat: 48.8566, centerLng: 2.3522, latitudeSpan: 0.05, longitudeSpan: 0.05
        ))

        #expect(result.tileCount == 3)
        #expect(result.pins.map(\.postID) == [PostID("post-1"), PostID("post-2")])
        #expect(result.pins.first?.thumbnailURL == URL(string: "mock://media/1"))
        // Photo-vs-video is stubbed to `.photo` until RadarPin.media_kind ships.
        #expect(result.pins.allSatisfy { $0.kind == .photo })
    }

    @Test func forwardsViewportAndZoomToTheService() async throws {
        let received = RequestBox()
        let repository = makeRepository { request in
            received.set(request)
            return GeoDiscovery_V1_QueryTileResponse()
        }

        _ = try await repository.queryTile(MapViewport(
            swLat: 48.80, swLng: 2.25, neLat: 48.91, neLng: 2.45, zoomLevel: 12
        ))

        let sent = received.value
        #expect(sent?.zoomLevel == 12)
        #expect(sent?.viewport.swLat == 48.80)
        #expect(sent?.viewport.neLng == 2.45)
    }

    @Test func skipsPinsWithoutAPostID() async throws {
        let repository = makeRepository { _ in
            var response = GeoDiscovery_V1_QueryTileResponse()
            response.pins = [
                self.radarPin("", lat: 1, lng: 1, thumb: "mock://x"),
                self.radarPin("post-9", lat: 2, lng: 2, thumb: "mock://y")
            ]
            return response
        }

        let result = try await repository.queryTile(.make(
            centerLat: 0, centerLng: 0, latitudeSpan: 10, longitudeSpan: 10
        ))

        #expect(result.pins.map(\.postID) == [PostID("post-9")])
    }

    /// An empty `thumbnail_url` is the ONLY "this post is text" signal the wire
    /// has (`RadarPin` carries no media kind), so it must both null the URL and
    /// classify the pin — a `.photo` with no cover is the blank grey square the
    /// text face exists to remove.
    @Test func emptyThumbnailMapsToATextPin() async throws {
        let repository = makeRepository { _ in
            var response = GeoDiscovery_V1_QueryTileResponse()
            response.pins = [
                self.radarPin("post-text", lat: 1, lng: 1, thumb: ""),
                self.radarPin("post-media", lat: 1, lng: 1, thumb: "mock://media/7")
            ]
            return response
        }

        let result = try await repository.queryTile(.make(
            centerLat: 0, centerLng: 0, latitudeSpan: 10, longitudeSpan: 10
        ))

        let text = result.pins.first { $0.postID == PostID("post-text") }
        #expect(text?.thumbnailURL == nil)
        #expect(text?.kind == .text)
        #expect(text?.isText == true)
        // A text pin has nothing to autoplay, whatever the DEBUG flags say.
        #expect(text?.previewVideoURL == nil)

        let media = result.pins.first { $0.postID == PostID("post-media") }
        #expect(media?.kind == .photo)
        #expect(media?.isText == false)
    }

    @Test func attachesFilterHeaderOnTheWire() async throws {
        // Phase-1 filter channel: the selection rides `x-map-filter`, not a
        // proto field (QueryTileRequest has none). Asserted via the transport's
        // request log, since the proto bytes can't carry it by construction.
        let bff = MockBFF()
        bff.register(path: "/geo_discovery.v1.GeoDiscoveryService/QueryTile") { (_: GeoDiscovery_V1_QueryTileRequest) in
            .success(GeoDiscovery_V1_QueryTileResponse())
        }
        let client = ConnectClientFactory.makeUnauthenticated(host: "https://mock.bff.local", httpClient: bff)
        let repository = GeoDiscoveryRepository(geoClient: GeoDiscovery_V1_GeoDiscoveryServiceClient(client: client))

        _ = try await repository.queryTile(
            .make(centerLat: 0, centerLng: 0, latitudeSpan: 1, longitudeSpan: 1),
            filter: .friends
        )

        let sent = bff.recordedRequests.first { $0.path.hasSuffix("/QueryTile") }
        #expect(sent?.headers[MapFilter.headerName] == ["friends"])
    }

    @Test func omitsFilterHeaderWhenUnfiltered() async throws {
        // A nil filter must leave the request byte- and header-identical to
        // the pre-filter call shape.
        let bff = MockBFF()
        bff.register(path: "/geo_discovery.v1.GeoDiscoveryService/QueryTile") { (_: GeoDiscovery_V1_QueryTileRequest) in
            .success(GeoDiscovery_V1_QueryTileResponse())
        }
        let client = ConnectClientFactory.makeUnauthenticated(host: "https://mock.bff.local", httpClient: bff)
        let repository = GeoDiscoveryRepository(geoClient: GeoDiscovery_V1_GeoDiscoveryServiceClient(client: client))

        _ = try await repository.queryTile(.make(
            centerLat: 0, centerLng: 0, latitudeSpan: 1, longitudeSpan: 1
        ))

        let sent = bff.recordedRequests.first { $0.path.hasSuffix("/QueryTile") }
        #expect(sent != nil)
        #expect(sent?.headers[MapFilter.headerName] == nil)
    }

    @Test func mockGeoServiceHonorsRelationshipFilters() async throws {
        // End-to-end over production wire bytes: repository → ProtocolClient →
        // MockBFF → MockGeoDiscoveryService, viewport wide enough to cover the
        // whole mock scatter. "Friends" must return a non-empty strict subset
        // of "following", which is a strict subset of "all" — the seeded graph
        // (2 mutuals ⊂ 4 followed ⊂ 8 authors) guarantees the gaps.
        let dataset = MockSocialDataset()
        let bff = MockBFF()
        MockGeoDiscoveryService(dataset: dataset).register(on: bff)
        let client = ConnectClientFactory.makeUnauthenticated(host: "https://mock.bff.local", httpClient: bff)
        let repository = GeoDiscoveryRepository(geoClient: GeoDiscovery_V1_GeoDiscoveryServiceClient(client: client))
        let paris = MapViewport.make(
            centerLat: 48.8566, centerLng: 2.3522, latitudeSpan: 0.5, longitudeSpan: 0.5
        )

        let all = try await repository.queryTile(paris)
        let following = try await repository.queryTile(paris, filter: .following)
        let friends = try await repository.queryTile(paris, filter: .friends)

        #expect(!friends.pins.isEmpty)
        #expect(friends.pins.count < following.pins.count)
        #expect(following.pins.count < all.pins.count)
        // Every friends pin belongs to a mutual author.
        let friendAuthors = Set(friends.pins.compactMap { pin in
            dataset.post(for: pin.postID.rawValue)?.authorProfileID
        })
        #expect(friendAuthors.isSubset(of: dataset.mutualProfileIDs))
    }

    @Test func mockGeoServiceHonorsProfileFavoriteFilter() async throws {
        // The favorites section's `profile:<id>` token: only that author's
        // posts survive.
        let dataset = MockSocialDataset()
        let bff = MockBFF()
        MockGeoDiscoveryService(dataset: dataset).register(on: bff)
        let client = ConnectClientFactory.makeUnauthenticated(host: "https://mock.bff.local", httpClient: bff)
        let repository = GeoDiscoveryRepository(geoClient: GeoDiscovery_V1_GeoDiscoveryServiceClient(client: client))
        let paris = MapViewport.make(
            centerLat: 48.8566, centerLng: 2.3522, latitudeSpan: 0.5, longitudeSpan: 0.5
        )

        let result = try await repository.queryTile(paris, filter: .profile(ProfileID("prof-3")))

        #expect(!result.pins.isEmpty)
        let authors = Set(result.pins.compactMap { pin in
            dataset.post(for: pin.postID.rawValue)?.authorProfileID
        })
        #expect(authors == ["prof-3"])
    }

    @Test func mockGeoServiceHonorsPinnedCategoryFilter() async throws {
        // The Places sub-filter's `pinned:<category>` token: only pinned
        // posts of that category survive, a strict subset of bare `pinned`.
        let dataset = MockSocialDataset()
        let bff = MockBFF()
        MockGeoDiscoveryService(dataset: dataset).register(on: bff)
        let client = ConnectClientFactory.makeUnauthenticated(host: "https://mock.bff.local", httpClient: bff)
        let repository = GeoDiscoveryRepository(geoClient: GeoDiscovery_V1_GeoDiscoveryServiceClient(client: client))
        let paris = MapViewport.make(
            centerLat: 48.8566, centerLng: 2.3522, latitudeSpan: 0.5, longitudeSpan: 0.5
        )

        let pinned = try await repository.queryTile(paris, filter: .pinned)
        let cafes = try await repository.queryTile(paris, filter: .pinnedCategory("cafes"))

        #expect(!cafes.pins.isEmpty)
        #expect(cafes.pins.count < pinned.pins.count)
        #expect(cafes.pins.allSatisfy { pin in
            dataset.pinnedPlaceCategories[pin.postID.rawValue] == "cafes"
        })
    }

    /// End-to-end over production wire bytes: a text-only post is indexed like
    /// any other and arrives as a `.text` pin. The mock used to drop them
    /// before the viewport test, so a third of the corpus was invisible on the
    /// map with nothing in the client saying so.
    @Test func mockGeoServiceIndexesTextOnlyPosts() async throws {
        let dataset = MockSocialDataset()
        let bff = MockBFF()
        MockGeoDiscoveryService(dataset: dataset).register(on: bff)
        let client = ConnectClientFactory.makeUnauthenticated(host: "https://mock.bff.local", httpClient: bff)
        let repository = GeoDiscoveryRepository(geoClient: GeoDiscovery_V1_GeoDiscoveryServiceClient(client: client))

        let result = try await repository.queryTile(.make(
            centerLat: 48.8566, centerLng: 2.3522, latitudeSpan: 0.5, longitudeSpan: 0.5
        ))

        let text = result.pins.filter(\.isText)
        #expect(!text.isEmpty)
        // Both kinds are on the map — text posts joined the field, they did not
        // replace it.
        #expect(result.pins.contains { !$0.isText })
        // A text pin's kind agrees with the dataset: no media on the record.
        #expect(text.allSatisfy { pin in
            dataset.post(for: pin.postID.rawValue)?.media == nil
        })
        // ...and every media post still carries its cover.
        #expect(result.pins.filter { !$0.isText }.allSatisfy { $0.thumbnailURL != nil })
    }

    @Test func surfacesTransportFailuresAsGeoDiscoveryError() async throws {
        // No route registered for QueryTile → MockBFF answers `unimplemented`,
        // which the repository must surface as a `.transport` error (not crash,
        // not silently succeed). Exercises the failure branch without naming
        // Connect's error type.
        let bff = MockBFF()
        let client = ConnectClientFactory.makeUnauthenticated(host: "https://mock.bff.local", httpClient: bff)
        let repository = GeoDiscoveryRepository(geoClient: GeoDiscovery_V1_GeoDiscoveryServiceClient(client: client))

        await #expect(throws: GeoDiscoveryError.self) {
            _ = try await repository.queryTile(.make(
                centerLat: 0, centerLng: 0, latitudeSpan: 1, longitudeSpan: 1
            ))
        }
    }
}

private final class RequestBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: GeoDiscovery_V1_QueryTileRequest?
    var value: GeoDiscovery_V1_QueryTileRequest? { lock.withLock { _value } }
    func set(_ request: GeoDiscovery_V1_QueryTileRequest) { lock.withLock { _value = request } }
}
