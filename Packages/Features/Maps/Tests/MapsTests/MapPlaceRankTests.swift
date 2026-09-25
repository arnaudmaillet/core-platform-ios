import FeedInterface
import Testing
@testable import Maps

/// A place's rank badge: its position, captioned by its KIND.
struct MapPlaceRankTests {
    @Test func theCaptionFollowsTheKind() {
        let city = MapPlace(id: "city:x", name: "X", kind: .city, rank: 3)
        let country = MapPlace(id: "country:y", name: "Y", kind: .country, rank: 12)
        #expect(city.rankBadge == PlaceRankBadge(position: 3, label: "City Rank"))
        #expect(city.rankBadge?.positionText == "#3")
        #expect(country.rankBadge == PlaceRankBadge(position: 12, label: "Country Rank"))
    }

    @Test func aPlaceWithoutARankHasNoBadge() {
        #expect(MapPlace(id: "city:x", name: "X", kind: .city).rankBadge == nil)
    }

    #if DEBUG
    /// The mock's own ask: Paris is "#3 City Rank".
    @Test func theMockRanksParisThird() {
        #expect(MapMockPlaces.paris.rankBadge == PlaceRankBadge(position: 3, label: "City Rank"))
    }
    #endif
}
