import CoreLocation
import Testing
@testable import Maps

/// The borders the map draws and unlocks: which country a point is in.
struct CountryAtlasTests {
    private let atlas = CountryAtlas.shared

    @Test func theAtlasIsBundled() {
        #expect(atlas.countries.count > 200, "only \(atlas.countries.count) countries loaded")
        #expect(atlas.country(code: "fr")?.name == "France")
    }

    @Test func aCityIsInItsCountry() {
        let cases: [(String, Double, Double)] = [
            ("FR", 48.8566, 2.3522),     // Paris
            ("GB", 51.5074, -0.1278),    // London
            ("US", 41.8781, -87.6298),   // Chicago (1:50m does not carve Manhattan)
            ("JP", 35.6762, 139.6503),   // Tokyo
            ("BR", -23.5505, -46.6333),  // São Paulo
            ("AU", -33.8688, 151.2093),  // Sydney
        ]
        for (code, lat, lon) in cases {
            let found = atlas.country(containing: CLLocationCoordinate2D(latitude: lat, longitude: lon))
            #expect(found?.code == code, "(\(lat), \(lon)) is \(found?.code ?? "nowhere"), not \(code)")
        }
    }

    @Test func theOpenSeaIsNoCountry() {
        #expect(atlas.country(containing: CLLocationCoordinate2D(latitude: 35, longitude: -40)) == nil)
    }

    /// The label point is where the rank annotation stands: it must be inside.
    @Test func everyLabelPointIsInsideItsCountry() {
        let outside = atlas.countries.filter { !$0.contains($0.label) }.map(\.code)
        #expect(outside.isEmpty, "label points outside their country: \(outside)")
    }

    @Test func aFlagIsTheRegionalIndicatorPair() {
        #expect(atlas.country(code: "FR")?.flag == "🇫🇷")
    }
}
