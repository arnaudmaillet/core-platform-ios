import CoreModels
import Foundation
import Testing
@testable import Maps

/// A favourite opens its profile AND its thread with what the pill shows
/// (#1860): the map's "Send Message" used to open a thread with an empty header.
@MainActor
struct MapFavoriteStubTests {
    @Test func aFavouritesStubCarriesWhatThePillShows() {
        let face = URL(string: "https://example.test/ava.jpg")!
        let stub = MapsViewController.stub(of: MapFavorite(profileID: ProfileID("ava"), title: "Ava", avatarURL: face, handle: "ava"))
        #expect(stub.displayName == "Ava")
        #expect(stub.handle == "ava")
        #expect(stub.avatarURL == face)
        #expect(stub.isFollowing == true, "a favourite is followed")
        // A favourite whose handle is unknown keeps its name, and invents none.
        let nameOnly = MapsViewController.stub(of: MapFavorite(profileID: ProfileID("bo"), title: "Bo"))
        #expect(nameOnly.displayName == "Bo")
        #expect(nameOnly.handle == nil)
    }
}
