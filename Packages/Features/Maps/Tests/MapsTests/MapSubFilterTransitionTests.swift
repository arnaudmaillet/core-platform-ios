import CoreModels
import Testing
import UIKit
@testable import Maps

/// A cross-dissolve lands the NEWEST row it was asked for.
///
/// ⚠️ **The handoff used to land the list it captured when it was scheduled.**
/// A primary switch fades the old pills out and swaps the new ones in ~150 ms
/// later; a refresh of the new primary arriving inside that window restacks
/// to a fresher list — and the stale handoff then overwrote it. The caller had
/// already recorded the fresh list as rendered, so nothing ever corrected the
/// row.
@MainActor
struct MapSubFilterTransitionTests {
    private static func person(_ id: String) -> MapSubFilterOption {
        MapSubFilterOption.people([
            MapFavorite(profileID: ProfileID(id), title: id.capitalized, avatarURL: nil, handle: nil)
        ])[0]
    }

    private static func carries(_ bar: MapSubFilterBarView, _ id: String) -> Bool {
        bar.entity(for: .profile(ProfileID(id))) != nil
    }

    /// Past the handoff (0.25 s fade × 0.6) with room to spare.
    private static func pastHandoff() async throws {
        try await Task.sleep(for: .milliseconds(400))
    }

    @Test("A restack during the swap is what the swap lands")
    func aRestackDuringTheSwapIsWhatLands() async throws {
        let bar = MapSubFilterBarView()
        bar.setOptions([Self.person("ava")])

        bar.transition(to: [Self.person("ben")])
        bar.restack(to: [Self.person("ben"), Self.person("cleo")])
        try await Self.pastHandoff()

        #expect(Self.carries(bar, "ben"))
        #expect(Self.carries(bar, "cleo"), "the swap landed the list it captured, not the fresh one")
        #expect(!Self.carries(bar, "ava"), "guard: the old primary's row was swapped out")
    }

    @Test("A swap with nothing arriving lands its own list")
    func aPlainSwapLandsItsList() async throws {
        let bar = MapSubFilterBarView()
        bar.setOptions([Self.person("ava")])

        bar.transition(to: [Self.person("ben")])
        try await Self.pastHandoff()

        #expect(Self.carries(bar, "ben"))
        #expect(!Self.carries(bar, "ava"))
    }

    @Test("A direct set supersedes a pending swap")
    func aDirectSetSupersedesTheSwap() async throws {
        let bar = MapSubFilterBarView()
        bar.setOptions([Self.person("ava")])

        bar.transition(to: [Self.person("ben")])
        bar.setOptions([Self.person("dan")])
        try await Self.pastHandoff()

        #expect(Self.carries(bar, "dan"))
        #expect(!Self.carries(bar, "ben"), "an abandoned swap landed after a direct set")
    }

    @Test("Outside a swap a restack applies at once")
    func aRestackOutsideASwapApplies() {
        let bar = MapSubFilterBarView()
        bar.setOptions([Self.person("ava")])

        bar.restack(to: [Self.person("ava"), Self.person("ben")])

        #expect(Self.carries(bar, "ben"))
    }
}
