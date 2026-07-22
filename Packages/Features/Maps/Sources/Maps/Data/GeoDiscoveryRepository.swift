import CoreContracts
import CoreModels
import Foundation
import MediaCore

public enum GeoDiscoveryError: Error, Equatable, Sendable {
    case transport(message: String)
}

/// The result of one Radar query: the pins in the viewport, plus the number of
/// H3 tiles the server touched. `tileCount` is a telemetry / "zoom in for more"
/// hint (a wide viewport spans many tiles → the response is Top-K-capped per
/// tile), never an error signal.
public struct TileResult: Sendable, Equatable {
    public let pins: [MapPin]
    public let tileCount: Int

    public init(pins: [MapPin], tileCount: Int) {
        self.pins = pins
        self.tileCount = tileCount
    }
}

/// What the map surface consumes; implemented by `GeoDiscoveryRepository`,
/// faked in view-model tests.
public protocol GeoDiscoveryProviding: Sendable {
    /// The Radar pan path: lightweight pins for the current viewport. Fail-open
    /// by contract (TIER-1) — a sparse/empty result is normal, and the caller
    /// must never block the map on it.
    ///
    /// `filter` narrows the result to one `MapFilter` bucket; `nil` is "all".
    /// Wire status is Phase 1 (see `MapFilter`): the selection rides a request
    /// header the mock honors and the fleet ignores.
    func queryTile(_ viewport: MapViewport, filter: MapFilter?) async throws -> TileResult
}

public extension GeoDiscoveryProviding {
    /// Unfiltered convenience — the pre-filter call shape.
    func queryTile(_ viewport: MapViewport) async throws -> TileResult {
        try await queryTile(viewport, filter: nil)
    }
}

/// Reads map pins from `geo_discovery.v1` over the authenticated edge. Maps the
/// generated `RadarPin` onto the MapKit-free `MapPin` projection.
public actor GeoDiscoveryRepository: GeoDiscoveryProviding {
    private let geoClient: any GeoDiscovery_V1_GeoDiscoveryServiceClientInterface

    public init(geoClient: any GeoDiscovery_V1_GeoDiscoveryServiceClientInterface) {
        self.geoClient = geoClient
    }

    public func queryTile(_ viewport: MapViewport, filter: MapFilter?) async throws -> TileResult {
        var request = GeoDiscovery_V1_QueryTileRequest()
        var box = GeoDiscovery_V1_Viewport()
        box.swLat = viewport.swLat
        box.swLng = viewport.swLng
        box.neLat = viewport.neLat
        box.neLng = viewport.neLng
        request.viewport = box
        request.zoomLevel = viewport.zoomLevel

        // Phase-1 filter channel (see `MapFilter`): a request header, not a
        // proto field — `QueryTileRequest` has none yet. Absent when nil, so
        // the unfiltered request stays byte-identical to the pre-filter one.
        let headers = filter.map { [MapFilter.headerName: [$0.wireToken]] } ?? [:]
        let response = await geoClient.queryTile(request: request, headers: headers)
        switch response.result {
        case .success(let body):
            return TileResult(
                pins: body.pins.compactMap(Self.makePin),
                tileCount: Int(body.tileCount)
            )
        case .failure(let error):
            throw GeoDiscoveryError.transport(message: error.message ?? "code \(error.code)")
        }
    }

    /// A `RadarPin` becomes a `MapPin` only if it carries a post id. An empty
    /// `thumbnail_url` (text-only post) maps to a `nil` URL rather than a broken
    /// marker image.
    static func makePin(from pin: GeoDiscovery_V1_RadarPin) -> MapPin? {
        guard !pin.postID.isEmpty else { return nil }
        let thumbnailURL = pin.thumbnailURL.isEmpty ? nil : URL(string: pin.thumbnailURL)
        let kind = mediaKind(for: pin)
        return MapPin(
            postID: PostID(pin.postID),
            latitude: pin.lat,
            longitude: pin.lng,
            thumbnailURL: thumbnailURL,
            mediaKind: kind,
            previewVideoURL: previewVideoURL(for: pin, kind: kind, thumbnailURL: thumbnailURL)
        )
    }

    /// Stubbed photo-vs-video discriminator. `RadarPin` has no media kind on the
    /// wire yet — the additive `media.v1.MediaKind media_kind = 5` field is not
    /// published to BSR — so in production every pin reads as an image and the
    /// play badge / live-preview autoplay stay dark.
    ///
    /// When the field ships and the contracts are regenerated, replace the
    /// production branch with `pin.mediaKind == .video ? .video : .image` (and
    /// add the `.video` case to `media.v1.MediaKind`).
    ///
    /// `-maps-force-video` (DEBUG) treats mock `video/*` pins as video so the
    /// badge and autoplay pool can be exercised live in the simulator before the
    /// field lands.
    static func mediaKind(for pin: GeoDiscovery_V1_RadarPin) -> MediaKind {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-maps-force-video"),
           pin.thumbnailURL.contains("video") {
            return .video
        }
        #endif
        return .image
    }

    /// The looping preview URL for a video pin. `nil` in production (Radar
    /// carries no video URL). Under `-maps-force-video`, the mock's
    /// `mock://video/*` thumbnail doubles as a synthesizable clip, so the pool
    /// has something real to play.
    static func previewVideoURL(for pin: GeoDiscovery_V1_RadarPin, kind: MediaKind, thumbnailURL: URL?) -> URL? {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-maps-force-video"), kind == .video {
            return thumbnailURL
        }
        #endif
        return nil
    }
}
