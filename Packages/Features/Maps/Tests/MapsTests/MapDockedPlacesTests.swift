import CoreNavigation
import CoreStorage
import Foundation
import Testing
@testable import Maps

/// The places pinned to the map's dock from their page (#1598): an ordered
/// list, toggled on and off, each a pill after the people that flies the map
/// to its place.
@MainActor
struct MapDockedPlacesTests {
    private func makeSuite() -> UserDefaults {
        // A suite per test: the runner is parallel.
        let suite = "maps-docked-places-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    private static let parisLink = PlaceLink.city(latitude: 48.8566, longitude: 2.3522, name: "Paris", countryCode: "FR")
    private static let paris = MapDockedPlacesStore.Entry(url: parisLink.url!.absoluteString, name: "Paris")
    private static let spain = MapDockedPlacesStore.Entry(
        url: PlaceLink.country(code: "ES").url!.absoluteString, name: "Spain"
    )

    @Test func togglingDocksThenUndocks() {
        let store = MapDockedPlacesStore(defaults: makeSuite())
        #expect(!store.isDocked(Self.paris.url))
        #expect(store.toggle(Self.paris) == true)
        #expect(store.isDocked(Self.paris.url))
        #expect(store.entries == [Self.paris])
        #expect(store.toggle(Self.paris) == false)
        #expect(store.entries.isEmpty)
    }

    /// The dock shows them in the order they were pinned; a re-pin goes last.
    @Test func theListKeepsPinOrder() {
        let store = MapDockedPlacesStore(defaults: makeSuite())
        store.toggle(Self.paris)
        store.toggle(Self.spain)
        #expect(store.entries == [Self.paris, Self.spain])
        store.toggle(Self.paris)
        store.toggle(Self.paris)
        #expect(store.entries == [Self.spain, Self.paris])
    }

    /// Two stores on one defaults are one list: the place page's and the map's.
    @Test func everyStoreReadsTheSameList() {
        let defaults = makeSuite()
        MapDockedPlacesStore(defaults: defaults).toggle(Self.spain)
        #expect(MapDockedPlacesStore(defaults: defaults).isDocked(Self.spain.url))
    }

    @Test func everyWritePostsTheChange() {
        let store = MapDockedPlacesStore(defaults: makeSuite())
        var posts = 0
        let observer = NotificationCenter.default.addObserver(
            forName: MapDockedPlacesStore.didChangeNotification, object: store, queue: nil
        ) { _ in posts += 1 }
        defer { NotificationCenter.default.removeObserver(observer) }
        store.toggle(Self.spain)
        store.toggle(Self.spain)
        #expect(posts == 2)
    }

    /// The profile is known after the map first reads its dock: a new
    /// owner is announced as a change, so the dock reads the profile's list.
    @Test func aNewOwnerIsAChange() {
        let defaults = makeSuite()
        let scope = StorageScope(owner: .member(account: "acct", profile: nil))
        let store = MapDockedPlacesStore(defaults: defaults, scope: scope)
        scope.owner = .member(account: "acct", profile: "prof")
        store.toggle(Self.spain)
        var posts = 0
        let observer = NotificationCenter.default.addObserver(
            forName: MapDockedPlacesStore.didChangeNotification, object: store, queue: nil
        ) { _ in posts += 1 }
        defer { NotificationCenter.default.removeObserver(observer) }
        scope.owner = .member(account: "acct", profile: "other")
        #expect(posts == 1)
        #expect(store.entries.isEmpty, "another profile's dock is its own")
        scope.owner = .member(account: "acct", profile: "prof")
        #expect(store.entries == [Self.spain])
    }

    /// The page's pin is the store's, keyed by the place's public link.
    @Test func thePagesPinIsTheDocksToggle() {
        let defaults = makeSuite()
        let pin = MapsFeatureBuilder.dockPin(for: Self.spain, store: MapDockedPlacesStore(defaults: defaults))
        #expect(!pin.isFollowing())
        #expect(pin.toggle())
        // The map's own store reads the page's write.
        #expect(MapDockedPlacesStore(defaults: defaults).entries == [Self.spain])
        #expect(pin.isFollowing())
    }

    /// Each docked place is a pill after the people, in pin order, one per
    /// place; a tap hands its place back to fly to.
    @Test func theDockShowsEachPlaceOnceAndATapFlies() {
        let bar = MapFilterBarView()
        bar.setDockedPlaces([Self.paris, Self.spain, Self.paris])
        #expect(bar.debugDockedPlaceURLs == [Self.paris.url, Self.spain.url])
        var flown: [MapDockedPlacesStore.Entry] = []
        bar.onPlaceTapped = { flown.append($0) }
        bar.debugTapPlace(Self.spain.url)
        #expect(flown == [Self.spain])
        bar.setDockedPlaces([])
        #expect(bar.debugDockedPlaceURLs.isEmpty)
    }

    /// Both link shapes the page's QR code carries read back as a place.
    @Test func aDockedLinkReadsBackAsItsPlace() throws {
        let countryURL = try #require(URL(string: Self.spain.url))
        #expect(PlaceLink(url: countryURL) == .country(code: "ES"))
        let cityURL = try #require(URL(string: Self.paris.url))
        #expect(PlaceLink(url: cityURL) == Self.parisLink)
    }
}
