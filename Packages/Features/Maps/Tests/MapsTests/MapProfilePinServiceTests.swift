import CoreModels
import Foundation
import Testing
@testable import Maps

/// THE PINNED LIST'S ONE TRICKY RULE.
///
/// `MapFavoritesStore` is tri-state, and the third state does the damage:
/// `nil` means "never curated", and the map then shows the people the viewer
/// FOLLOWS. So a followed profile is already pinned as far as the viewer can
/// see, and the first write has to materialize that list before editing it —
/// write a bare `[id]` instead and every other person silently leaves the rail.
///
/// It matters more now than when the map was the only caller: the profile
/// screen's pin button writes through this same service, so the rule has to
/// live in one place and be pinned by tests rather than re-derived per screen.
struct MapProfilePinServiceTests {
    /// A `following()` list, and nothing else the service asks for.
    private struct StubFavorites: MapFavoritesProviding {
        let followed: [ProfileID]

        func profiles(for ids: [ProfileID]) async -> [MapFavorite] { [] }
        func friends() async -> [MapFavorite] { [] }
        func following() async -> [MapFavorite] {
            followed.map { MapFavorite(profileID: $0, title: $0.rawValue) }
        }
    }

    /// A store on its own `UserDefaults` suite, so suites running in parallel
    /// cannot read each other's list — `.standard` is one shared mutable
    /// object and these tests write to it.
    private func makeStore(_ name: String = UUID().uuidString) -> MapFavoritesStore {
        MapFavoritesStore(defaults: UserDefaults(suiteName: name)!)
    }

    private func makeService(
        store: MapFavoritesStore, following: [ProfileID]
    ) -> MapProfilePinService {
        MapProfilePinService(store: store, favorites: StubFavorites(followed: following))
    }

    // MARK: - Reading

    /// Never curated: what the rail SHOWS is the following list, so that is
    /// what "pinned" has to mean. Reporting false here would put an unpinned
    /// button on a profile the map is already showing.
    @Test func aFollowedProfileReadsAsPinnedBeforeAnyCuration() async {
        let service = makeService(store: makeStore(), following: [ProfileID("a"), ProfileID("b")])

        #expect(await service.isPinned(ProfileID("a")))
        #expect(await service.isPinned(ProfileID("zzz")) == false)
    }

    @Test func aCuratedListIsAuthoritative() async {
        let store = makeStore()
        store.setPinned([ProfileID("a")])
        // `b` is followed but NOT curated — once the viewer has a list, the
        // graph stops deciding what the rail holds.
        let service = makeService(store: store, following: [ProfileID("a"), ProfileID("b")])

        #expect(await service.isPinned(ProfileID("a")))
        #expect(await service.isPinned(ProfileID("b")) == false)
    }

    // MARK: - Writing

    /// The defect this rule exists to prevent: unpinning one person out of an
    /// uncurated rail must keep everyone else on it.
    @Test func theFirstUnpinMaterializesTheRestOfTheRail() async {
        let store = makeStore()
        let following = [ProfileID("a"), ProfileID("b"), ProfileID("c")]
        let service = makeService(store: store, following: following)

        await service.setPinned(false, for: ProfileID("b"))

        #expect(store.pinnedProfileIDs == [ProfileID("a"), ProfileID("c")])
        #expect(await service.isPinned(ProfileID("a")), "an unrelated person fell off the rail")
    }

    @Test func pinningSomeoneNewKeepsThePeopleAlreadyThere() async {
        let store = makeStore()
        let service = makeService(store: store, following: [ProfileID("a")])

        await service.setPinned(true, for: ProfileID("z"))

        #expect(store.pinnedProfileIDs == [ProfileID("a"), ProfileID("z")])
    }

    /// A viewer who pins someone already effectively pinned has still MADE a
    /// choice, and the list must stop tracking the graph from then on —
    /// otherwise a later unfollow would quietly rewrite their rail.
    @Test func aNoOpPinStillCommitsTheChoice() async {
        let store = makeStore()
        let service = makeService(store: store, following: [ProfileID("a")])

        await service.setPinned(true, for: ProfileID("a"))

        #expect(store.pinnedProfileIDs == [ProfileID("a")], "the fallback was left uncommitted")
    }

    @Test func writingIsIdempotent() async {
        let store = makeStore()
        let service = makeService(store: store, following: [])

        await service.setPinned(true, for: ProfileID("a"))
        await service.setPinned(true, for: ProfileID("a"))
        await service.setPinned(false, for: ProfileID("ghost"))

        #expect(store.pinnedProfileIDs == [ProfileID("a")], "a repeat pin duplicated the entry")
    }

    @Test func aRoundTripReturnsToTheStartingPoint() async {
        let store = makeStore()
        let service = makeService(store: store, following: [ProfileID("a")])

        await service.setPinned(true, for: ProfileID("z"))
        await service.setPinned(false, for: ProfileID("z"))

        #expect(await service.isPinned(ProfileID("z")) == false)
        #expect(await service.isPinned(ProfileID("a")))
    }

    // MARK: - Telling the map

    /// The map may already be on screen behind the profile that wrote. Without
    /// this notification its rail keeps yesterday's list, which reads as the
    /// pin button having done nothing at all.
    @Test func everyWriteAnnouncesItself() async {
        let store = makeStore()
        let service = makeService(store: store, following: [])
        let box = Box()
        // Scoped to THIS store: suites run in parallel and every one of them
        // writes to a store of its own.
        let token = NotificationCenter.default.addObserver(
            forName: MapFavoritesStore.didChangeNotification, object: store, queue: nil
        ) { _ in box.bump() }
        defer { NotificationCenter.default.removeObserver(token) }

        await service.setPinned(true, for: ProfileID("a"))

        #expect(box.count == 1)
    }

    private final class Box: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        var count: Int { lock.withLock { value } }
        func bump() { lock.withLock { value += 1 } }
    }
}
