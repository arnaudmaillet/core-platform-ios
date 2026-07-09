import CoreContracts
import CoreModels
import CoreNetworking
import CoreNetworkingMocks
import Foundation
import MediaCore
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
        // Media kind is stubbed to `.image` until RadarPin.media_kind ships.
        #expect(result.pins.allSatisfy { $0.mediaKind == .image })
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

    @Test func emptyThumbnailMapsToNilURL() async throws {
        let repository = makeRepository { _ in
            var response = GeoDiscovery_V1_QueryTileResponse()
            response.pins = [self.radarPin("post-text", lat: 1, lng: 1, thumb: "")]
            return response
        }

        let result = try await repository.queryTile(.make(
            centerLat: 0, centerLng: 0, latitudeSpan: 10, longitudeSpan: 10
        ))

        #expect(result.pins.first?.thumbnailURL == nil)
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
