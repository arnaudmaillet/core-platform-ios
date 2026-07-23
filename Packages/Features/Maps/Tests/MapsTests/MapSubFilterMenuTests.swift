import CoreModels
import Testing
import UIKit
@testable import Maps

/// The sub-filter pill's long-press menu: which verbs an entity offers, and
/// where each one lands.
///
/// Split in two on purpose. The ladder is pure values, so it is asserted
/// directly; the ROUTING is asserted by invoking `perform(_:on:)` — a
/// `UIAction`'s handler cannot be called from a test, so a menu assembled
/// inline would only ever be checkable on its titles, and "Share opens the
/// share sheet, Remove removes" would go untested.
@MainActor
struct MapSubFilterMenuTests {
    private static func person(_ id: String) -> MapSubFilterOption {
        MapSubFilterOption.people([
            MapFavorite(profileID: ProfileID(id), title: id.uppercased(), avatarURL: nil, handle: id)
        ])[0]
    }

    private static var place: MapSubFilterOption { MapSubFilterOption.placeCategories[0] }

    /// A `.profile` refinement whose `MapFavorite` never hydrated — a real
    /// state, and the only way to reach the generic ladder.
    private static func namelessProfile(_ id: String) -> MapSubFilterOption {
        MapSubFilterOption(
            subFilter: .profile(ProfileID(id)),
            content: MapPillButton.Content(
                title: id, symbolName: "person.crop.circle",
                selectedSymbolName: "person.crop.circle.fill", accessibilityLabel: id
            ),
            favorite: nil
        )
    }

    /// A bar already carrying `options`, with every menu callback recorded.
    private static func makeBar(_ options: [MapSubFilterOption]) -> (MapSubFilterBarView, Recorder) {
        let bar = MapSubFilterBarView()
        let recorder = Recorder()
        bar.onViewProfile = { recorder.viewedProfile = $0 }
        bar.onSendMessage = { recorder.messaged = $0 }
        bar.onToggleMute = { recorder.muted = $0 }
        bar.onViewDetails = { recorder.details = $0 }
        bar.onShare = { recorder.shared = $0 }
        bar.onUnpinSubFilter = { recorder.unpinned = $0 }
        bar.setOptions(options)
        return (bar, recorder)
    }

    private final class Recorder {
        var viewedProfile: MapFavorite?
        var messaged: MapFavorite?
        var muted: MapFavorite?
        var details: String?
        var shared: MapSubFilterOption?
        var unpinned: MapSubFilter?

        /// Everything that did NOT fire, so a test can assert a verb reached
        /// exactly one destination instead of merely reaching its own.
        var firedCount: Int {
            [viewedProfile != nil, messaged != nil, muted != nil,
             details != nil, shared != nil, unpinned != nil].filter { $0 }.count
        }
    }

    // MARK: - Entity resolution

    @Test("A refinement with a favorite behind it is a person")
    func personEntity() {
        #expect(MapSubFilterEntity(option: Self.person("ava")) == .person(
            MapFavorite(profileID: ProfileID("ava"), title: "AVA", avatarURL: nil, handle: "ava")
        ))
    }

    @Test("A place category resolves to its token, not its display name")
    func placeEntity() {
        #expect(MapSubFilterEntity(option: Self.place) == .place("cafes"))
    }

    @Test("A person the bar can't name falls back to generic")
    func unhydratedProfileIsGeneric() {
        // Not padding: offering "View Profile" here would open an empty screen.
        #expect(MapSubFilterEntity(option: Self.namelessProfile("ghost")) == .generic)
    }

    // MARK: - The ladders

    @Test("A person offers the full ladder, destructive last")
    func personLadder() {
        #expect(MapSubFilterMenuAction.actions(for: .person(
            MapFavorite(profileID: ProfileID("a"), title: "A")
        )) == [.viewProfile, .sendMessage, .toggleMute, .share, .unpin])
    }

    @Test("A place offers details, share, remove — nothing account-shaped")
    func placeLadder() {
        #expect(MapSubFilterMenuAction.actions(for: .place("cafes"))
            == [.viewDetails, .share, .unpin])
    }

    @Test("Generic offers only the verbs that need no identity")
    func genericLadder() {
        #expect(MapSubFilterMenuAction.actions(for: .generic) == [.share, .unpin])
    }

    @Test("Every ladder ends in the destructive removal, and only that is destructive")
    func onlyRemovalIsDestructive() {
        let entities: [MapSubFilterEntity] = [
            .person(MapFavorite(profileID: ProfileID("a"), title: "A")), .place("cafes"), .generic
        ]
        for entity in entities {
            let ladder = MapSubFilterMenuAction.actions(for: entity)
            #expect(ladder.last == .unpin)
            #expect(ladder.filter(\.isDestructive) == [.unpin])
        }
    }

    // MARK: - Titles and glyphs

    @Test("Each action carries the specified glyph")
    func glyphs() {
        let expected: [MapSubFilterMenuAction: String] = [
            .viewProfile: "person.crop.circle",
            .sendMessage: "message",
            .toggleMute: "bell.slash",
            .viewDetails: "info.circle",
            .share: "square.and.arrow.up",
            .unpin: "pin.slash"
        ]
        for (action, symbol) in expected {
            #expect(action.symbolName(isMuted: false) == symbol, "\(action)")
            // Every one of them must actually exist in SF Symbols, or the row
            // renders a hole.
            #expect(UIImage(systemName: symbol) != nil, "\(symbol)")
        }
    }

    @Test("Mute is the only entry whose wording tracks live state")
    func muteTitleFlips() {
        #expect(MapSubFilterMenuAction.toggleMute.title(isMuted: false) == "Mute")
        #expect(MapSubFilterMenuAction.toggleMute.title(isMuted: true) == "Unmute")
        #expect(MapSubFilterMenuAction.toggleMute.symbolName(isMuted: true) == "bell")
        for action in MapSubFilterMenuAction.allCases where action != .toggleMute {
            #expect(action.title(isMuted: true) == action.title(isMuted: false), "\(action)")
        }
    }

    // MARK: - Routing

    @Test("Every person verb reaches its own callback and no other")
    func personRouting() {
        let option = Self.person("ava")
        let cases: [(MapSubFilterMenuAction, (Recorder) -> Bool)] = [
            (.viewProfile, { $0.viewedProfile?.profileID == ProfileID("ava") }),
            (.sendMessage, { $0.messaged?.profileID == ProfileID("ava") }),
            (.toggleMute, { $0.muted?.profileID == ProfileID("ava") }),
            (.share, { $0.shared?.subFilter == option.subFilter }),
            (.unpin, { $0.unpinned == option.subFilter })
        ]
        for (action, check) in cases {
            let (bar, recorder) = Self.makeBar([option])
            bar.perform(action, on: option.subFilter)
            #expect(check(recorder), "\(action) did not reach its callback")
            #expect(recorder.firedCount == 1, "\(action) fired more than one callback")
        }
    }

    @Test("View Details hands over the category token")
    func placeRouting() {
        let option = Self.place
        let (bar, recorder) = Self.makeBar([option])
        bar.perform(.viewDetails, on: option.subFilter)
        #expect(recorder.details == "cafes")
        #expect(recorder.firedCount == 1)
    }

    @Test("Share on a place hands over the whole option, so the host can title it")
    func placeShareRouting() {
        let option = Self.place
        let (bar, recorder) = Self.makeBar([option])
        bar.perform(.share, on: option.subFilter)
        #expect(recorder.shared?.sheetTitle == "Cafes")
    }

    @Test("A person verb on a nameless profile can't fire — there is nobody to hand over")
    func genericRoutingIsInertForAccountVerbs() {
        let option = Self.namelessProfile("ghost")
        let (bar, recorder) = Self.makeBar([option])
        for action in [MapSubFilterMenuAction.viewProfile, .sendMessage, .toggleMute, .viewDetails] {
            bar.perform(action, on: option.subFilter)
        }
        #expect(recorder.firedCount == 0)
        // …but the two identity-free verbs still work.
        bar.perform(.share, on: option.subFilter)
        bar.perform(.unpin, on: option.subFilter)
        #expect(recorder.shared?.subFilter == option.subFilter)
        #expect(recorder.unpinned == option.subFilter)
    }

    @Test("A verb aimed at a refinement the row no longer carries is inert")
    func routingAnUnknownSubFilterDoesNothing() {
        let (bar, recorder) = Self.makeBar([Self.person("ava")])
        bar.perform(.unpin, on: .profile(ProfileID("someone-else")))
        #expect(recorder.firedCount == 0)
    }

    // MARK: - Assembled menu

    @Test("The built menu matches the ladder, one child per action")
    func menuMirrorsTheLadder() {
        let person = Self.person("ava")
        let place = Self.place
        let (bar, _) = Self.makeBar([person, place])

        let personMenu = bar.menu(for: person.subFilter)
        #expect(personMenu?.children.count == 5)
        #expect(personMenu?.children.compactMap { ($0 as? UIAction)?.title }
            == ["View Profile", "Message", "Mute", "Share", "Remove"])

        let placeMenu = bar.menu(for: place.subFilter)
        #expect(placeMenu?.children.compactMap { ($0 as? UIAction)?.title }
            == ["View Details", "Share", "Remove"])
        // The removal is marked destructive so UIKit tints it red.
        #expect((placeMenu?.children.last as? UIAction)?.attributes.contains(.destructive) == true)
    }

    @Test("The menu reads mute state when it is BUILT, not when the pill was configured")
    func menuReadsLiveMuteState() {
        let option = Self.person("ava")
        let (bar, _) = Self.makeBar([option])
        var muted = false
        bar.isMuted = { _ in muted }
        #expect((bar.menu(for: option.subFilter)?.children[2] as? UIAction)?.title == "Mute")
        muted = true
        #expect((bar.menu(for: option.subFilter)?.children[2] as? UIAction)?.title == "Unmute")
    }

    @Test("A refinement the row doesn't carry has no menu at all")
    func unknownSubFilterHasNoMenu() {
        let (bar, _) = Self.makeBar([Self.person("ava")])
        #expect(bar.menu(for: .placeCategory("nope")) == nil)
        #expect(bar.entity(for: .placeCategory("nope")) == nil)
    }
}
