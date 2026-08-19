import Testing
import CoreGraphics
@testable import Profile

/// Where an empty tab's message lands, on screens the developing device is not.
///
/// Every number here was measured with `-profile-layout-audit`, which prints the
/// band and the block on whatever simulator it runs on.
struct ProfileEmptyStatePlacementTests {
    /// iPhone SE 3, pushed profile: a 99pt block and nine points to put it in.
    /// Centring hid the glyph behind the tab selector.
    @Test func aBandTooSmallForTheBlockStartsItBelowTheHeader() {
        let centre = ProfileEmptyStatePlacement.centreY(
            visibleTop: 564, visibleBottom: 573, blockHeight: 99
        )
        #expect(centre - 99 / 2 == 564)
    }

    /// iPhone 17, same block, 174pt of band: the centre wins and nothing moves.
    @Test func aBandWithRoomCentresTheBlockInIt() {
        let centre = ProfileEmptyStatePlacement.centreY(
            visibleTop: 606, visibleBottom: 780, blockHeight: 99
        )
        #expect(centre == 693)
    }

    /// The block's top NEVER rises above the band's top — the whole point, and
    /// the one property that has to hold at every size.
    @Test func theBlockNeverRisesAboveTheBandsTop() {
        for bandHeight in stride(from: CGFloat(-40), through: 400, by: 20) {
            let top: CGFloat = 500
            let centre = ProfileEmptyStatePlacement.centreY(
                visibleTop: top, visibleBottom: top + bandHeight, blockHeight: 99
            )
            #expect(centre - 99 / 2 >= top)
        }
    }

    /// The own profile on iPhone SE 3 goes NEGATIVE — the header's bottom sits
    /// below the tab bar's top, so there is no band at all. It still has to
    /// resolve to "just below the header" rather than to some point above it.
    @Test func aNegativeBandStillPlacesTheBlockBelowTheHeader() {
        let centre = ProfileEmptyStatePlacement.centreY(
            visibleTop: 544, visibleBottom: 526, blockHeight: 99
        )
        #expect(centre - 99 / 2 == 544)
    }

    /// A taller block needs a taller band before centring takes over; the
    /// crossover is where the band exactly fits it.
    @Test func centringTakesOverExactlyWhenTheBlockFits() {
        let top: CGFloat = 100
        let block: CGFloat = 80
        let tight = ProfileEmptyStatePlacement.centreY(
            visibleTop: top, visibleBottom: top + block, blockHeight: block
        )
        #expect(tight == top + block / 2)
        let roomy = ProfileEmptyStatePlacement.centreY(
            visibleTop: top, visibleBottom: top + block + 40, blockHeight: block
        )
        #expect(roomy == top + (block + 40) / 2)
    }
}
