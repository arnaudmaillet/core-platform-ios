import Foundation

/// The client's current map viewport, in the exact shape `geo_discovery.v1`
/// expects: an axis-aligned WGS-84 bounding box plus a 0–15 zoom level the
/// server bands onto H3 resolutions.
///
/// Kept UIKit/MapKit-free so the region→bbox conversion and the zoom mapping
/// are unit-tested without a live `MKMapView`. The view controller builds one
/// of these from `MKCoordinateRegion` via `make(center:span:)`.
public struct MapViewport: Sendable, Equatable {
    /// South-west (bottom-left) corner.
    public let swLat: Double
    public let swLng: Double
    /// North-east (top-right) corner.
    public let neLat: Double
    public let neLng: Double
    /// Raw client zoom, clamped to the server's accepted 0–15 range.
    public let zoomLevel: Int32

    public init(swLat: Double, swLng: Double, neLat: Double, neLng: Double, zoomLevel: Int32) {
        self.swLat = swLat
        self.swLng = swLng
        self.neLat = neLat
        self.neLng = neLng
        self.zoomLevel = zoomLevel
    }

    /// Every coordinate on Earth, at the widest zoom.
    public static let world = MapViewport(swLat: -90, swLng: -180, neLat: 90, neLng: 180, zoomLevel: 0)

    /// Builds a viewport from a MapKit region's center + span (all in degrees).
    /// The corners are the center offset by half the span on each axis; the zoom
    /// is derived from the longitude span (see `zoomLevel(forLongitudeSpan:)`).
    ///
    /// ⚠️ **A VIEW ACROSS THE ANTIMERIDIAN GETS EVERY LONGITUDE.** The box is
    /// axis-aligned and cannot wrap, and clamping its edge to ±180 dropped
    /// the far side: a camera over the Pacific (or any view wide enough to
    /// reach the line, which the widest zoom often is) asked for Fiji's west
    /// and never its east. Widened, the query covers both; the zoom still
    /// comes from the real span, so the server bands it the same.
    ///
    /// A region with a non-finite value asks for the world rather than
    /// sending NaN corners to the server.
    public static func make(
        centerLat: Double,
        centerLng: Double,
        latitudeSpan: Double,
        longitudeSpan: Double
    ) -> MapViewport {
        guard centerLat.isFinite, centerLng.isFinite,
              latitudeSpan.isFinite, longitudeSpan.isFinite else { return world }
        let halfLat = latitudeSpan / 2
        let halfLng = longitudeSpan / 2
        let west = centerLng - halfLng
        let east = centerLng + halfLng
        let wraps = west < -180 || east > 180
        return MapViewport(
            swLat: (centerLat - halfLat).clamped(to: -90...90),
            swLng: wraps ? -180 : west,
            neLat: (centerLat + halfLat).clamped(to: -90...90),
            neLng: wraps ? 180 : east,
            zoomLevel: zoomLevel(forLongitudeSpan: longitudeSpan)
        )
    }

    /// Maps a longitude span (degrees of the visible viewport) onto the server's
    /// 0–15 zoom scale: the whole world (360°) is zoom 0, and each halving of
    /// the span is one zoom level up. The server re-bands this onto H3
    /// resolutions, so the client only needs a monotonic, view-size-independent
    /// approximation — not pixel-accurate tile math.
    public static func zoomLevel(forLongitudeSpan span: Double) -> Int32 {
        guard span > 0, span < 360 else { return 0 }
        let raw = log2(360.0 / span)
        return Int32(raw.rounded()).clamped(to: 0...15)
    }
}

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
