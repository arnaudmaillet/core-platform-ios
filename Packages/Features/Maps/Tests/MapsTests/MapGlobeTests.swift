import MapKit
import Testing
@testable import Maps

/// `MapGlobe`: the standard map up close, the hybrid globe far out, with a
/// gap between the two thresholds so a camera resting near one cannot flip
/// the map's style back and forth.
@MainActor
struct MapGlobeTests {
    /// The premise the hysteresis rests on: entry is FARTHER than exit.
    @Test func entryIsFartherThanExit() {
        #expect(MapGlobe.entryDistance > MapGlobe.exitDistance)
    }

    @Test func theMapBecomesTheGlobeOnlyPastTheEntry() {
        let entry = MapGlobe.entryDistance
        #expect(!MapGlobe.showsGlobe(atDistance: 26_715, showingGlobe: false))
        #expect(!MapGlobe.showsGlobe(atDistance: entry * 0.9, showingGlobe: false))
        #expect(MapGlobe.showsGlobe(atDistance: entry * 1.1, showingGlobe: false))
    }

    /// Between the two thresholds the answer is whatever is on screen.
    @Test func betweenTheThresholdsTheMapKeepsItsFace() {
        let between = (MapGlobe.entryDistance + MapGlobe.exitDistance) / 2
        #expect(MapGlobe.showsGlobe(atDistance: between, showingGlobe: true))
        #expect(!MapGlobe.showsGlobe(atDistance: between, showingGlobe: false))
    }

    @Test func theGlobeGoesBackToTheMapOnlyInsideTheExit() {
        let exit = MapGlobe.exitDistance
        #expect(MapGlobe.showsGlobe(atDistance: exit * 1.1, showingGlobe: true))
        #expect(!MapGlobe.showsGlobe(atDistance: exit * 0.9, showingGlobe: true))
    }

    /// The globe is MapKit's only for its imagery configurations; the map
    /// is the standard one. Both keep POIs excluded — a configuration
    /// carries its own filter, and one without it brings them back.
    @Test func theConfigurationsAndTheirFilters() throws {
        let globe = try #require(MapGlobe.configuration(globe: true) as? MKHybridMapConfiguration)
        #expect(globe.elevationStyle == .realistic)
        #expect(globe.pointOfInterestFilter?.includes(.restaurant) == false)
        let map = try #require(MapGlobe.configuration(globe: false) as? MKStandardMapConfiguration)
        #expect(map.elevationStyle == .flat)
        #expect(map.pointOfInterestFilter?.includes(.restaurant) == false)
    }
}
