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

    /// What a pin puts in its single `thumbnail_url` field.
    ///
    /// `RadarPin` has exactly one URL and no media kind, which is the gap
    /// `dev/issues/BACKEND_MEDIA_PREVIEW_RENDITIONS.md` §C exists to close: a
    /// video pin has nowhere to say "this is a video, here is a cheap loop".
    /// The client therefore renders every pin through the image pipeline unless
    /// `-maps-force-video` is on, so this has to follow the same rule:
    ///
    /// - Default — a **still**. Under `.realAssets` a video post's media URL is
    ///   an HLS manifest or an MP4, which the image pipeline cannot decode, so
    ///   it is swapped for a real photograph. Handing the raw video URL over
    ///   here renders a blank pin, which is a fixture bug, not a finding.
    /// - Under `-maps-force-video` — the lightweight **preview loop**, never
    ///   the full stream. A pin must not be able to open an HLS ladder mid-pan,
    ///   which is the whole point of the contract ask. Its `mock-kind=video`
    ///   marker is what `GeoDiscoveryRepository.mediaKind(for:)` matches on.
    static func pinURL(forMediaURL url: String, catalog: MockSocialDataset.MediaCatalog) -> String {
        guard catalog == .realAssets, MockMediaFixtures.isVideoURL(url) else { return url }
        return forcesMapVideo
            ? MockMediaFixtures.mapPreviewLoop.url
            : MockMediaFixtures.imageURL(index: url.count, width: 256, height: 256)
    }

    /// Mirrors the Maps feature's own DEBUG launch argument. Read here so the
    /// fixture a pin carries matches how the client will classify it.
    static let forcesMapVideo = ProcessInfo.processInfo.arguments.contains("-maps-force-video")

    public func register(on bff: MockBFF) {
        bff.register(path: "/geo_discovery.v1.GeoDiscoveryService/QueryTile") { [self] (request: GeoDiscovery_V1_QueryTileRequest, headers: Headers) in
            queryTile(request, filter: headers[Self.filterHeader]?.first)
        }
    }

    /// The Phase-1 map-filter side channel: `QueryTileRequest` has no filter
    /// field on the wire, so the Maps repository sends the active pill as this
    /// request header. The values are `MapFilter.rawValue` strings from the
    /// Maps feature, matched literally here (this package can't import it);
    /// unknown or absent tokens fail open to "all".
    static let filterHeader = "x-map-filter"

    private func queryTile(
        _ request: GeoDiscovery_V1_QueryTileRequest,
        filter: String?
    ) -> Result<GeoDiscovery_V1_QueryTileResponse, ConnectError> {
        let viewport = request.viewport
        var response = GeoDiscovery_V1_QueryTileResponse()

        let pins = dataset.posts.enumerated().compactMap { index, post -> GeoDiscovery_V1_RadarPin? in
            guard let media = post.media else { return nil } // text-only posts aren't mapped
            let (lat, lng) = Self.coordinate(forIndex: index)
            guard Self.contains(viewport: viewport, lat: lat, lng: lng),
                  matches(filter: filter, post: post, lat: lat, lng: lng, viewport: viewport)
            else { return nil }

            var pin = GeoDiscovery_V1_RadarPin()
            pin.postID = post.postID
            pin.lat = lat
            pin.lng = lng
            pin.thumbnailURL = Self.pinURL(forMediaURL: media.url, catalog: dataset.mediaCatalog)
            return pin
        }

        response.pins = Array(pins.prefix(Self.topK))
        // Stand-in tile count: scales with how wide the viewport is.
        response.tileCount = Int32(max(1, pins.count / 12 + 1))
        return .success(response)
    }

    /// One `MapFilter` bucket, resolved against the shared dataset:
    /// - `friends` / `following`: author-set intersection (the backend's
    ///   documented client-side design, playable here because the mock knows
    ///   authorship even though `RadarPin` carries no `author_id`).
    /// - `pinned`: the dataset's seeded saved-places set.
    /// - `nearby`: a tight radius around the viewport center (the mock has no
    ///   user location; the center is the stand-in).
    /// - `profile:<id>`: that profile's posts only (the bar's favorites).
    private func matches(
        filter: String?,
        post: MockSocialDataset.PostRecord,
        lat: Double,
        lng: Double,
        viewport: GeoDiscovery_V1_Viewport
    ) -> Bool {
        // Multi-selection (the sub-filter row's multi-select) arrives as its
        // leaf tokens joined by commas, with OR semantics: a pin matching any
        // member is shown.
        if let filter, filter.contains(",") {
            return filter.split(separator: ",").contains { member in
                matches(
                    filter: String(member), post: post, lat: lat, lng: lng, viewport: viewport
                )
            }
        }
        switch filter {
        case "friends":
            return dataset.mutualProfileIDs.contains(post.authorProfileID)
        case "following":
            return dataset.followedProfileIDs.contains(post.authorProfileID)
        case "pinned":
            return dataset.pinnedPostIDs.contains(post.postID)
        case "nearby":
            let centerLat = (viewport.swLat + viewport.neLat) / 2
            let centerLng = (viewport.swLng + viewport.neLng) / 2
            let dLat = lat - centerLat
            let dLng = lng - centerLng
            return dLat * dLat + dLng * dLng <= Self.nearbyRadius * Self.nearbyRadius
        default:
            if let filter, filter.hasPrefix("profile:") {
                return post.authorProfileID == String(filter.dropFirst("profile:".count))
            }
            if let filter, filter.hasPrefix("pinned:") {
                // Places narrowed to one category (the sub-filter row).
                let category = String(filter.dropFirst("pinned:".count))
                return dataset.pinnedPlaceCategories[post.postID] == category
            }
            return true // no/unknown filter → fail open, show everything
        }
    }

    /// "Nearby" cutoff in degrees (~4 km) — well inside the ±0.15° scatter,
    /// so selecting the pill visibly thins the field at the default zoom.
    private static let nearbyRadius = 0.04

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
