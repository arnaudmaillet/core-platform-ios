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

    @Test func clampsCornersToValidRanges() {
        // A pole-spanning span must not push corners past ±90 / ±180.
        let viewport = MapViewport.make(
            centerLat: 89,
            centerLng: 179,
            latitudeSpan: 20,
            longitudeSpan: 20
        )
        #expect(viewport.neLat == 90)
        #expect(viewport.neLng == 180)
        #expect(viewport.swLat == 79)
        #expect(viewport.swLng == 169)
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
