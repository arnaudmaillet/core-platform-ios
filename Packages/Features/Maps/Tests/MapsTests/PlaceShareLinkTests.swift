import CoreLocation
import CoreNavigation
import Foundation
import Testing
@testable import Maps

/// A place's share link (#985): what the server lists its posts by, so the
/// link opens the same place anywhere — never the mock's `MapPlace.id`.
@MainActor
struct PlaceShareLinkTests {
    @Test func aCountrySharesItsCode() throws {
        let place = MapPlace(id: "country:france", name: "France", kind: .country)
        let url = try #require(MapsFeatureBuilder.shareURL(of: place, countryCode: "fr", centre: nil))
        #expect(url.absoluteString == "https://\(AppRoute.webHost)/place/country/FR")
        #expect(AppRoute(deepLink: url) == .place(.country(code: "FR")))
        #expect(!url.absoluteString.contains("country:france"), "the mock's identity leaked into the link")
    }

    @Test func aCitySharesItsPointAndName() throws {
        let place = MapPlace(id: "city:paris", name: "Paris", kind: .city)
        let centre = CLLocationCoordinate2D(latitude: 48.8566, longitude: 2.3522)
        let url = try #require(MapsFeatureBuilder.shareURL(of: place, countryCode: "FR", centre: centre))
        #expect(AppRoute(deepLink: url) == .place(.city(latitude: 48.8566, longitude: 2.3522, name: "Paris", countryCode: "FR")))
    }

    /// At sea: no country, no centre — nothing to share.
    @Test func aPlaceTheServerCannotNameSharesNothing() {
        #expect(MapsFeatureBuilder.shareURL(of: MapPlace(id: "country:x", name: "X", kind: .country), countryCode: "", centre: nil) == nil)
        #expect(MapsFeatureBuilder.shareURL(of: MapPlace(id: "city:x", name: "X", kind: .city), countryCode: "", centre: nil) == nil)
    }
}
