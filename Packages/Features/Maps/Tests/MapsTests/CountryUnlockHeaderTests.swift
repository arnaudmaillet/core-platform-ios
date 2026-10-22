import DesignSystem
import Testing
import UIKit
@testable import Maps

/// The unlock sheet's header is the place identity row (`PlaceIdentityView`,
/// whose layout DesignSystem's tests pin) filled with the COUNTRY: its large
/// round flag, its name and continent, its rank and its likes — the place
/// page's own arrangement since #1600 (`.page`, #1597).
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

    /// The place page's block (#1600): the rank a column like the likes,
    /// at one size, never a bubble.
    @Test func theCountersAreTheRankThenTheLikesLikeThePlacePage() throws {
        let identity = try header("ES")
        #expect(identity.layout == .page)
        #expect(identity.statViews.map(\.captionLabel.text) == ["Likes"])
        #expect(identity.statViews.map(\.valueLabel.text) == ["8.7K"])
        let rank = try #require(identity.rankStat)
        #expect(rank.valueLabel.text == "#4" && !rank.isHidden)
        #expect(identity.rankBubble.isHidden, "a bubble rode the flag")
        #expect(rank.valueLabel.font.pointSize == identity.statViews[0].valueLabel.font.pointSize,
                "the rank and the likes are not one size")
    }
}
