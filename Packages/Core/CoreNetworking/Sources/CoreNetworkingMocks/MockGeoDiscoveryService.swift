import Connect
import CoreContracts
import Foundation

/// Fake of geo_discovery.v1.GeoDiscoveryService over the shared dataset. Radar
/// path only for now (QueryTile) — the Focus path (GetGeoTimeline) arrives with
/// the Maps tap/hero transition in Step B.
///
/// The mock dataset has no coordinates, so pins are scattered deterministically
/// around central Paris (matching the map's default region) from the post's
/// index. Only posts with media are indexed — text-only posts are never placed
/// on the map (mirrors the backend's DOMAIN §6: no location → not indexed).
/// The result is filtered to the requested viewport and Top-K capped, so pan/
/// zoom and clustering behave like the real service without a fleet.
public final class MockGeoDiscoveryService: @unchecked Sendable {
    private let dataset: MockSocialDataset

    /// Central Paris — the map's default region centers here.
    private static let baseLat = 48.8566
    private static let baseLng = 2.3522
    /// Scatter radius in degrees (~±16 km), enough to exercise pan and clustering.
    private static let spread = 0.15
    /// Per-response cap, standing in for the server's per-tile Top-K.
    private static let topK = 80

    public init(dataset: MockSocialDataset) {
        self.dataset = dataset
    }

    public func register(on bff: MockBFF) {
        bff.register(path: "/geo_discovery.v1.GeoDiscoveryService/QueryTile") { [self] (request: GeoDiscovery_V1_QueryTileRequest) in
            queryTile(request)
        }
    }

    private func queryTile(
        _ request: GeoDiscovery_V1_QueryTileRequest
    ) -> Result<GeoDiscovery_V1_QueryTileResponse, ConnectError> {
        let viewport = request.viewport
        var response = GeoDiscovery_V1_QueryTileResponse()

        let pins = dataset.posts.enumerated().compactMap { index, post -> GeoDiscovery_V1_RadarPin? in
            guard let media = post.media else { return nil } // text-only posts aren't mapped
            let (lat, lng) = Self.coordinate(forIndex: index)
            guard Self.contains(viewport: viewport, lat: lat, lng: lng) else { return nil }

            var pin = GeoDiscovery_V1_RadarPin()
            pin.postID = post.postID
            pin.lat = lat
            pin.lng = lng
            pin.thumbnailURL = media.url
            return pin
        }

        response.pins = Array(pins.prefix(Self.topK))
        // Stand-in tile count: scales with how wide the viewport is.
        response.tileCount = Int32(max(1, pins.count / 12 + 1))
        return .success(response)
    }

    /// Deterministic scatter: two coprime strides over the index fan posts out
    /// across the box without randomness, so runs are reproducible.
    private static func coordinate(forIndex index: Int) -> (lat: Double, lng: Double) {
        let latFraction = Double((index * 73) % 1000) / 1000.0
        let lngFraction = Double((index * 137) % 1000) / 1000.0
        let lat = baseLat + (latFraction * 2 - 1) * spread
        let lng = baseLng + (lngFraction * 2 - 1) * spread
        return (lat, lng)
    }

    private static func contains(viewport: GeoDiscovery_V1_Viewport, lat: Double, lng: Double) -> Bool {
        lat >= viewport.swLat && lat <= viewport.neLat
            && lng >= viewport.swLng && lng <= viewport.neLng
    }
}
