import DesignSystem
import Testing
import UIKit
@testable import Maps

/// The unlock sheet's header is the place identity row (`PlaceIdentityView`,
/// whose layout DesignSystem's tests pin) filled with the COUNTRY: its large
/// round flag, its name and continent, its likes and posts, its rank.
@MainActor
struct CountryUnlockHeaderTests {
    private func header(_ code: String, standing: CountryStanding? = nil) throws -> PlaceIdentityView {
        let country = try #require(CountryAtlas.shared.country(code: code))
        return CountryUnlockSheetViewController.header(
            country: country,
            standing: standing ?? CountryStanding(code: code, rank: 4, likes: 8_700, posts: 86, price: 50)
        )
    }

    @Test func theFlagIsTheCountrysLargeRoundFlag() throws {
        let identity = try header("ES")
        let large = try #require(FlagPalette.largeRoundFlag(for: "ES"))
        #expect(identity.flagView.image === large, "not the 96pt round flag")
    }

    @Test func theTitleIsTheNameAndItsContinent() throws {
        let identity = try header("ES")
        #expect(identity.titleLabel.name == "Spain")
        #expect(identity.titleLabel.subtitle == "Europe")
    }

    @Test func theCountersAreLikesThenPostsAndTheRankRidesTheFlag() throws {
        let identity = try header("ES")
        #expect(identity.statViews.map(\.captionLabel.text) == ["Likes", "Posts"])
        #expect(identity.statViews.map(\.valueLabel.text) == ["8.7K", "86"])
        #expect(identity.rankBubble.label.text == "#4")
        #expect(!identity.rankBubble.isHidden)
    }

    @Test func aSinglePostIsOnePost() throws {
        let identity = try header("ES", standing: CountryStanding(code: "ES", rank: 9, likes: 3, posts: 1, price: 15))
        #expect(identity.statViews.map(\.captionLabel.text) == ["Likes", "Post"])
    }
}
