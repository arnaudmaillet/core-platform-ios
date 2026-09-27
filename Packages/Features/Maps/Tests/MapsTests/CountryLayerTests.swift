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
        #expect(lifted.lineWidth == 1.5, "a rim, not a marker stroke")
    }

    /// The lift is the copy's opacity: 0 is invisible, 1 fully risen.
    @Test func theLiftFadesTheCopy() throws {
        let france = try #require(CountryAtlas.shared.country(code: "FR"))
        let lifted = CountryRenderer(shape: CountryShape(country: france, lifted: true))
        #expect(lifted.lift == 1 && lifted.alpha == 1)
        lifted.lift = 0
        #expect(lifted.alpha == 0)
        lifted.lift = 0.5
        #expect(lifted.alpha == 0.5)
    }

    /// A badge's view carries an empty margin MapKit collides on, but only
    /// the badge itself takes a touch.
    @Test func aBadgeKeepsItsDistanceButOnlyItsBodyIsTappable() throws {
        let spain = try #require(CountryAtlas.shared.country(code: "ES"))
        let badge = LockedCountryAnnotation(
            country: spain, standing: CountryStanding(code: "ES", rank: 4, likes: 1, posts: 1, price: 50)
        )
        let view = LockedCountryAnnotationView(annotation: badge, reuseIdentifier: nil)
        let margin = LockedCountryAnnotationView.collisionMargin
        #expect(view.bounds.width > 2 * margin.width && view.bounds.height > 2 * margin.height)
        #expect(!view.point(inside: CGPoint(x: 2, y: 2), with: nil), "the margin is empty map")
        #expect(view.point(inside: CGPoint(x: view.bounds.midX, y: view.bounds.midY), with: nil))
    }
}
