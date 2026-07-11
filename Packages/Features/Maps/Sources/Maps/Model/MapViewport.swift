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

    /// Builds a viewport from a MapKit region's center + span (all in degrees).
    /// The corners are the center offset by half the span on each axis; the zoom
    /// is derived from the longitude span (see `zoomLevel(forLongitudeSpan:)`).
    public static func make(
        centerLat: Double,
        centerLng: Double,
        latitudeSpan: Double,
        longitudeSpan: Double
    ) -> MapViewport {
        let halfLat = latitudeSpan / 2
        let halfLng = longitudeSpan / 2
        return MapViewport(
            swLat: (centerLat - halfLat).clamped(to: -90...90),
            swLng: (centerLng - halfLng).clamped(to: -180...180),
            neLat: (centerLat + halfLat).clamped(to: -90...90),
            neLng: (centerLng + halfLng).clamped(to: -180...180),
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
