import MapKit
import Testing
@testable import Maps

/// The renderers the map asks for every country.
@MainActor
struct CountryLayerTests {
    /// MapKit builds a renderer through `init(overlay:)` from inside its own
    /// initialisers; a subclass missing it traps on the first draw.
    @Test func aCountryGetsARenderer() throws {
        let france = try #require(CountryAtlas.shared.country(code: "FR"))
        let layer = CountryLayer()
        let renderer = try #require(layer.renderer(for: CountryShape(country: france)) as? CountryRenderer)
        #expect(renderer.style == .unlocked)
        #expect(renderer.lineWidth == 1)
        let lifted = CountryRenderer(shape: CountryShape(country: france, lifted: true))
        #expect(lifted.lineWidth == 3)
    }
}
