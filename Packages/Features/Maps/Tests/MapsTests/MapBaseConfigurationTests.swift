import MapKit
import Testing
@testable import Maps

/// `MapBaseConfiguration`: one map at every zoom — the standard map, flat,
/// its points of interest excluded.
@MainActor
struct MapBaseConfigurationTests {
    /// The standard map (never imagery, whose realistic style swaps in a
    /// satellite globe), flat.
    @Test func theMapIsTheFlatStandardMap() throws {
        let map = try #require(MapBaseConfiguration.make() as? MKStandardMapConfiguration)
        #expect(map.elevationStyle == .flat)
        #expect(map.emphasisStyle == .default)
    }

    /// The configuration states its POI filter: a configuration carries its
    /// own, so one built without it brings the POIs back.
    @Test func pointsOfInterestAreExcluded() throws {
        let map = try #require(MapBaseConfiguration.make() as? MKStandardMapConfiguration)
        #expect(map.pointOfInterestFilter?.includes(.restaurant) == false)
    }
}
