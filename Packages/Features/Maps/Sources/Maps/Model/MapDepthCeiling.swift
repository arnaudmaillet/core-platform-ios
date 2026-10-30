import CoreLocation
import MapKit

/// The deepest place band a viewer may reach on a map (#1907, the owner
/// 2026-10-30), in the banding's own terms — not a zoom number.
///
/// | Ceiling | What the viewer can reach |
/// |---|---|
/// | `.country` | the world map: every country, nothing deeper |
/// | `.city` | every city, and the countries |
/// | `.unlocked` | everything, down to single posts |
enum MapDepthCeiling: Equatable, Sendable {
    case country
    case city
    case unlocked

    /// The band the ceiling stops at; nil for `.unlocked`.
    var kind: MapPlace.Kind? {
        switch self {
        case .country: .country
        case .city: .city
        case .unlocked: nil
        }
    }

    /// The guest without location roams at country level (#1907); everyone
    /// else — members, and a guest who allowed location — is unlocked.
    static func policy(isMember: Bool, locationAllowed: Bool) -> MapDepthCeiling {
        isMember || locationAllowed ? .unlocked : .country
    }
}

/// How close the camera may come under a ceiling, from the banding itself
/// (`MapHierarchyBanding`) — one source of truth, never a second table.
enum MapDepthLimit {
    /// Kept above the dissolve point, so the band can never flip at the limit.
    static let margin = 1.08

    /// The smallest viewport diagonal (km) at which `kind` still renders,
    /// from the corpus's spans: `span × dissolveSpanMultiple`, with the
    /// margin. Nil when the corpus has no span for it (the zoom fallback).
    static func smallestDiagonalKm(for kind: MapPlace.Kind, spans: [MapPlace.Kind: Double]) -> Double? {
        spans[kind].map { $0 * MapHierarchyBanding.dissolveSpanMultiple * margin }
    }

    /// The smallest longitude span (degrees) at which `kind` still renders
    /// under the zoom fallback (`MapHierarchyBanding.fallbackKind`: country
    /// up to zoom 5, city up to 11), with the margin — the fleet today, with
    /// no place identity at all.
    static func smallestLongitudeSpan(for kind: MapPlace.Kind) -> Double {
        let deepestZoom: Double = kind == .country ? 5 : 11
        // `zoomLevel(forLongitudeSpan:)` rounds: zoom 5 holds below 5.5.
        return 360 / pow(2, deepestZoom + 0.5) * margin
    }
}

/// Keeps an `MKMapView`'s camera from closing past a ceiling (#1907):
/// `cameraZoomRange`, so pinch, double tap, the one-finger zoom and every
/// programmatic move stop at the limit with MapKit's own resistance. Pan and
/// rotation are free. Attach it to any map; the host sets the ceiling. It
/// knows nothing about guests, locations or countries.
///
/// ⚠️ THE LIMIT IS A CAMERA DISTANCE, the banding's a viewport measure (a
/// diagonal, or a longitude span for the fallback). The two are tied by the
/// view's size and MapKit's camera, so the clamp reads their ratio off the
/// live map (`calibrate`), at rest, and converts — re-read whenever the
/// region changes, which covers a rotation and a size change.
@MainActor
final class MapDepthClamp {
    private weak var mapView: MKMapView?

    var ceiling: MapDepthCeiling = .unlocked {
        didSet { if ceiling != oldValue { apply() } }
    }

    /// The corpus's spans per kind (`MapClusterEngine`); empty → fallback.
    var spans: [MapPlace.Kind: Double] = [:] {
        didSet { if spans != oldValue { apply() } }
    }

    /// The camera distance the limit is at now; nil with no limit.
    private(set) var minimumDistance: CLLocationDistance?

    /// Metres of camera distance per km of diagonal, and per degree of
    /// longitude span, read off the live map.
    private var metresPerDiagonalKm: Double?
    private var metresPerLongitudeDegree: Double?

    init(mapView: MKMapView) {
        self.mapView = mapView
    }

    /// Reads the camera's distance against the visible region. Call when the
    /// map settles (`regionDidChangeAnimated`).
    func calibrate() {
        guard let mapView, mapView.bounds.width > 0, mapView.camera.pitch < 1 else { return }
        let distance = mapView.camera.centerCoordinateDistance
        let region = mapView.region
        guard distance > 0, region.span.longitudeDelta > 0, region.span.longitudeDelta < 180 else { return }
        let diagonal = Self.diagonalKm(of: region)
        guard diagonal > 0 else { return }
        metresPerDiagonalKm = distance / diagonal
        metresPerLongitudeDegree = distance / region.span.longitudeDelta
        apply()
    }

    /// The camera distance at which the ceiling's band dissolves, from the
    /// ratios read off the map. Pure, for tests.
    static func minimumDistance(
        ceiling: MapDepthCeiling, spans: [MapPlace.Kind: Double],
        metresPerDiagonalKm: Double?, metresPerLongitudeDegree: Double?
    ) -> CLLocationDistance? {
        guard let kind = ceiling.kind else { return nil }
        if let diagonal = MapDepthLimit.smallestDiagonalKm(for: kind, spans: spans), let ratio = metresPerDiagonalKm {
            return diagonal * ratio
        }
        guard spans.isEmpty || spans[kind] == nil, let ratio = metresPerLongitudeDegree else { return nil }
        return MapDepthLimit.smallestLongitudeSpan(for: kind) * ratio
    }

    private func apply() {
        guard let mapView else { return }
        let limit = Self.minimumDistance(
            ceiling: ceiling, spans: spans,
            metresPerDiagonalKm: metresPerDiagonalKm, metresPerLongitudeDegree: metresPerLongitudeDegree
        )
        // No limit yet (not calibrated): a ceiling still applies once the
        // map has settled once; unlocked lifts it at once.
        if ceiling == .unlocked {
            guard minimumDistance != nil else { return }
            minimumDistance = nil
            mapView.cameraZoomRange = nil
            return
        }
        guard let limit else { return }
        if let current = minimumDistance, abs(current - limit) / max(limit, 1) < 0.01 { return }
        minimumDistance = limit
        mapView.cameraZoomRange = MKMapView.CameraZoomRange(minCenterCoordinateDistance: limit)
    }

    /// A region's diagonal, in km — the banding's measure, one formula for
    /// both (`MapsViewController.currentViewportDiagonalKm`).
    static func diagonalKm(of region: MKCoordinateRegion) -> Double {
        let latKm = region.span.latitudeDelta * 111.0
        let lngKm = region.span.longitudeDelta * 111.0 * max(0.01, cos(region.center.latitude * .pi / 180))
        return (latKm * latKm + lngKm * lngKm).squareRoot()
    }
}
