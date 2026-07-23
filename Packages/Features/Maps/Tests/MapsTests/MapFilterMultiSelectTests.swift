import CoreModels
import Testing
@testable import Maps

/// Multi-selection on the wire: several refinements collapse into one `any`
/// token with OR semantics, and survive the round trip the mock parses.
struct MapFilterMultiSelectTests {
    private static let lena = MapFilter.profile(ProfileID("prof-2"))
    private static let marcus = MapFilter.profile(ProfileID("prof-3"))

    @Test func oneFilterResolvesToItself() {
        #expect(MapFilter.resolved([Self.lena]) == Self.lena)
        #expect(MapFilter.resolved([]) == nil)
    }

    @Test func severalCollapseIntoOneOrderedAnyToken() {
        let resolved = MapFilter.resolved([Self.marcus, Self.lena])
        #expect(resolved == .any([Self.lena, Self.marcus]))
        // Sets are unordered — the header must not churn between two
        // identical selections, so members are sorted by token.
        #expect(resolved?.wireToken == "profile:prof-2,profile:prof-3")
        #expect(MapFilter.resolved([Self.lena, Self.marcus])?.wireToken == resolved?.wireToken)
    }

    @Test func duplicatesAndNestingFlatten() {
        let nested = MapFilter.any([Self.lena, Self.marcus])
        #expect(MapFilter.resolved([nested, Self.lena]) == .any([Self.lena, Self.marcus]))
    }

    @Test func anyTokenRoundTripsThroughTheWire() {
        let resolved = MapFilter.resolved([Self.lena, .pinnedCategory("parks")])
        let parsed = MapFilter(wireToken: resolved!.wireToken)
        #expect(parsed == resolved)
    }

    @Test func mixedTokensParseBackToTheirLeaves() {
        let parsed = MapFilter(wireToken: "friends,pinned:cafes")
        #expect(parsed == .any([.friends, .pinnedCategory("cafes")]))
    }
}
