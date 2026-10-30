import MapKit
import Testing
import UIKit
@testable import Maps

/// The depth ceiling (#1907): the deepest place band a viewer may reach,
/// kept by the camera's zoom range, from the banding's own rule.
@MainActor
struct MapDepthCeilingTests {
    @Test func aGuestWithoutLocationRoamsAtCountryLevelEveryoneElseIsUnlocked() {
        #expect(MapDepthCeiling.policy(isMember: false, locationAllowed: false) == .country)
        #expect(MapDepthCeiling.policy(isMember: false, locationAllowed: true) == .unlocked)
        #expect(MapDepthCeiling.policy(isMember: true, locationAllowed: false) == .unlocked)
        #expect(MapDepthCeiling.policy(isMember: true, locationAllowed: true) == .unlocked)
    }

    /// The invariant: at the closest view the ceiling allows, the band that
    /// renders is the ceiling's, never a deeper one — with spans (dynamic)
    /// and without (the zoom fallback).
    @Test(arguments: [MapPlace.Kind.country, .city])
    func theClosestViewAllowedStillRendersTheCeilingsBand(_ kind: MapPlace.Kind) throws {
        let spans: [MapPlace.Kind: Double] = [.country: 837.4, .city: 17.1]
        let diagonal = try #require(MapDepthLimit.smallestDiagonalKm(for: kind, spans: spans))
        #expect(MapHierarchyBanding.activeKind(viewportDiagonalKm: diagonal, spansByKind: spans, zoomLevel: nil) == kind)

        let span = MapDepthLimit.smallestLongitudeSpan(for: kind)
        let zoom = MapViewport.zoomLevel(forLongitudeSpan: span)
        #expect(MapHierarchyBanding.activeKind(viewportDiagonalKm: nil, spansByKind: [:], zoomLevel: zoom) == kind,
                "the fallback's limit lands at zoom \(zoom)")
    }

    /// Unlocked sets no limit; a ceiling converts its band's measure through
    /// the ratios read off the map.
    @Test func theLimitIsTheBandsMeasureThroughTheMapsRatio() throws {
        #expect(MapDepthClamp.minimumDistance(
            ceiling: .unlocked, spans: [.country: 800], metresPerDiagonalKm: 2_000, metresPerLongitudeDegree: 200_000
        ) == nil)
        let spans: [MapPlace.Kind: Double] = [.country: 800]
        let dynamic = try #require(MapDepthClamp.minimumDistance(
            ceiling: .country, spans: spans, metresPerDiagonalKm: 2_000, metresPerLongitudeDegree: 200_000
        ))
        #expect(abs(dynamic - 800 * MapHierarchyBanding.dissolveSpanMultiple * MapDepthLimit.margin * 2_000) < 1)
        let fallback = try #require(MapDepthClamp.minimumDistance(
            ceiling: .country, spans: [:], metresPerDiagonalKm: 2_000, metresPerLongitudeDegree: 200_000
        ))
        #expect(abs(fallback - MapDepthLimit.smallestLongitudeSpan(for: .country) * 200_000) < 1)
    }

    /// On a bare `MKMapView` — no `MapsViewController` — a ceiling sets the
    /// camera's zoom range once the map has been read, and unlocked lifts it.
    @Test func theClampSetsAndLiftsTheMapsZoomRange() {
        let map = MKMapView(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        let window = UIWindow(frame: map.frame)
        window.addSubview(map)
        window.isHidden = false
        defer { window.isHidden = true }
        map.setRegion(MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: 46, longitude: 2),
            span: MKCoordinateSpan(latitudeDelta: 40, longitudeDelta: 40)
        ), animated: false)
        map.layoutIfNeeded()
        let unlimited = map.cameraZoomRange.minCenterCoordinateDistance
        let clamp = MapDepthClamp(mapView: map)
        clamp.ceiling = .country
        clamp.calibrate()
        let limit = clamp.minimumDistance
        #expect(limit != nil, "a country ceiling set no limit")
        #expect(map.cameraZoomRange.minCenterCoordinateDistance == limit ?? -1)
        clamp.ceiling = .unlocked
        #expect(clamp.minimumDistance == nil)
        #expect(map.cameraZoomRange.minCenterCoordinateDistance == unlimited, "unlocked kept a limit")
    }
}
