import CoreModels
import Testing
import UIKit
@testable import Maps

/// The row's identity only ever gains detail.
///
/// A menu header is drawn from the `MapFavorite` the row is holding, so a
/// person arriving without their handle renders a one-line header — and if a
/// fuller favorite lands while that menu is open, the header grows a second
/// line under the viewer's thumb. These pin the rule that prevents it: once
/// the bar has seen a handle for a profile, it keeps it.
@MainActor
struct MapSubFilterHandleCacheTests {
    private static func bar(_ options: [MapSubFilterOption]) -> MapSubFilterBarView {
        let bar = MapSubFilterBarView()
        bar.setOptions(options)
        return bar
    }

    private static func person(_ id: String, handle: String?) -> MapSubFilterOption {
        MapSubFilterOption.people([
            MapFavorite(
                profileID: ProfileID(id),
                title: id.capitalized,
                avatarURL: nil,
                handle: handle
            )
        ])[0]
    }

    private static func subtitle(of bar: MapSubFilterBarView, _ id: String) -> String? {
        let menu = bar.menu(for: .profile(ProfileID(id)))
        return (menu?.children.first as? UIMenu)?.children
            .compactMap { $0 as? UIAction }.first?.subtitle
    }

    @Test("A handle that arrives is used immediately")
    func aHandleIsUsedImmediately() {
        let bar = Self.bar([Self.person("ava", handle: "ava.moreau")])

        #expect(Self.subtitle(of: bar, "ava") == "@ava.moreau")
    }

    /// The case the recording showed, in reverse: a later, thinner favorite
    /// must not take the handle away.
    @Test("A restack without the handle keeps the one already known")
    func aThinnerFavoriteKeepsTheHandle() {
        let bar = Self.bar([Self.person("ava", handle: "ava.moreau")])

        bar.restack(to: [Self.person("ava", handle: nil)])

        #expect(Self.subtitle(of: bar, "ava") == "@ava.moreau")
    }

    /// An empty handle is the same absence as nil — the wire sends "" for a
    /// profile that has none.
    @Test("An empty handle is treated as absent")
    func anEmptyHandleIsAbsent() {
        let bar = Self.bar([Self.person("ava", handle: "ava.moreau")])

        bar.restack(to: [Self.person("ava", handle: "")])

        #expect(Self.subtitle(of: bar, "ava") == "@ava.moreau")
    }

    /// And nothing is invented: a profile the bar has never seen named stays
    /// unnamed rather than borrowing someone else's handle.
    @Test("A profile never seen with a handle has none")
    func nothingIsInvented() {
        let bar = Self.bar([Self.person("ava", handle: "ava.moreau")])

        bar.restack(to: [Self.person("kenji", handle: nil)])

        #expect(Self.subtitle(of: bar, "kenji") == nil)
    }
}
