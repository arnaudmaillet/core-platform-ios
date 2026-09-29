import Testing
@testable import Maps

struct MapViewportTests {
    @Test func derivesCornersFromCenterAndSpan() {
        let viewport = MapViewport.make(
            centerLat: 48.8566,
            centerLng: 2.3522,
            latitudeSpan: 0.10,
            longitudeSpan: 0.20
        )
        #expect(abs(viewport.swLat - 48.8066) < 1e-9)
        #expect(abs(viewport.neLat - 48.9066) < 1e-9)
        #expect(abs(viewport.swLng - 2.2522) < 1e-9)
        #expect(abs(viewport.neLng - 2.4522) < 1e-9)
    }

    @Test func clampsLatitudeToThePoles() {
        // A pole-spanning span must not push corners past ±90.
        let viewport = MapViewport.make(
            centerLat: 89,
            centerLng: 10,
            latitudeSpan: 20,
            longitudeSpan: 20
        )
        #expect(viewport.neLat == 90)
        #expect(viewport.swLat == 79)
        #expect(viewport.swLng == 0)
        #expect(viewport.neLng == 20)
    }

    /// A view across the antimeridian cannot be one axis-aligned box: it asks
    /// for every longitude rather than dropping the far side of the line
    /// (clamping gave 169...180 for this camera — Fiji's east was never
    /// queried).
    @Test func aViewAcrossTheAntimeridianAsksForEveryLongitude() {
        let east = MapViewport.make(centerLat: -17, centerLng: 179, latitudeSpan: 20, longitudeSpan: 20)
        #expect(east.swLng == -180)
        #expect(east.neLng == 180)
        #expect(east.swLat == -27)
        #expect(east.neLat == -7)
        let west = MapViewport.make(centerLat: 64, centerLng: -175, latitudeSpan: 10, longitudeSpan: 30)
        #expect(west.swLng == -180)
        #expect(west.neLng == 180)
        // The zoom still comes from the span the camera shows, not the box.
        #expect(east.zoomLevel == MapViewport.zoomLevel(forLongitudeSpan: 20))
    }

    /// The widest zoom: a span of the whole world, or more, is the world.
    @Test func aWorldWideSpanIsTheWorld() {
        let viewport = MapViewport.make(centerLat: 0, centerLng: 0, latitudeSpan: 180, longitudeSpan: 360)
        #expect(viewport == .world)
    }

    /// A view that touches the line without crossing it keeps its box.
    @Test func aViewEndingOnTheAntimeridianKeepsItsBox() {
        let viewport = MapViewport.make(centerLat: 0, centerLng: 170, latitudeSpan: 10, longitudeSpan: 20)
        #expect(viewport.swLng == 160)
        #expect(viewport.neLng == 180)
    }

    /// A region with a non-finite value asks for the world, never NaN corners.
    @Test func aNonFiniteRegionAsksForTheWorld() {
        #expect(MapViewport.make(centerLat: .nan, centerLng: 0, latitudeSpan: 1, longitudeSpan: 1) == .world)
        #expect(MapViewport.make(centerLat: 0, centerLng: 0, latitudeSpan: .infinity, longitudeSpan: 1) == .world)
        #expect(MapViewport.make(centerLat: 0, centerLng: 0, latitudeSpan: 1, longitudeSpan: .nan) == .world)
    }

    @Test func mapsLongitudeSpanOntoZoomBands() {
        // Whole world → most zoomed out.
        #expect(MapViewport.zoomLevel(forLongitudeSpan: 360) == 0)
        #expect(MapViewport.zoomLevel(forLongitudeSpan: 400) == 0)
        // Each halving of the span is one zoom level up.
        #expect(MapViewport.zoomLevel(forLongitudeSpan: 180) == 1)
        #expect(MapViewport.zoomLevel(forLongitudeSpan: 90) == 2)
        // A tiny street-level span saturates at the server's ceiling.
        #expect(MapViewport.zoomLevel(forLongitudeSpan: 0.0001) == 15)
    }

    @Test func zoomIsMonotonicAsYouZoomIn() {
        let wide = MapViewport.zoomLevel(forLongitudeSpan: 10)
        let mid = MapViewport.zoomLevel(forLongitudeSpan: 1)
        let tight = MapViewport.zoomLevel(forLongitudeSpan: 0.1)
        #expect(wide < mid)
        #expect(mid < tight)
    }
}
