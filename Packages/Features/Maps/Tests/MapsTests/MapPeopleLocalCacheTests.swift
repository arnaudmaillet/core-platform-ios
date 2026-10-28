import CoreModels
import Foundation
import LocalStore
import MapsInterface
import Testing
@testable import Maps

/// The map's people on the device (#1776): the dock and the Friends /
/// Following rows open on their last people at the next launch.
struct MapPeopleLocalCacheTests {
    private final class Folder: Sendable {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "MapPeopleLocalCacheTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        deinit { try? FileManager.default.removeItem(at: url) }
    }

    private let folder = Folder()

    private func launch(as viewer: LocalStoreViewer = .member(account: "acct-1", profile: "me")) throws -> MapPeopleLocalCache {
        MapPeopleLocalCache(store: try LocalStore(directory: folder.url, viewer: { viewer }))
    }

    private let people = [
        MapFavorite(profileID: ProfileID("ava"), title: "Ava", avatarURL: URL(string: "https://cdn.example/ava.jpg"), handle: "ava"),
        MapFavorite(profileID: ProfileID("leo"), title: "@leo"),
    ]

    @Test func eachSlotComesBackInItsOrderAtTheNextLaunch() throws {
        let cache = try launch()
        #expect(cache.people(.dock) == nil, "a cold device has people")
        cache.store(people, in: .dock, as: cache.viewer)
        cache.store(Array(people.reversed()), in: .friendsRow, as: cache.viewer)
        cache.waitForPendingWrites()

        let relaunched = try launch()
        #expect(relaunched.people(.dock) == people)
        #expect(relaunched.people(.friendsRow) == Array(people.reversed()), "a slot took another's order")
        #expect(relaunched.people(.followingRow) == nil)
    }

    @Test func aCatalogueIsCapped() throws {
        let cache = try launch()
        let many = (0..<(MapPeopleLocalCache.maxStoredPeople + 20)).map {
            MapFavorite(profileID: ProfileID("p\($0)"), title: "P\($0)")
        }
        cache.store(many, in: .followingCatalogue, as: cache.viewer)
        cache.waitForPendingWrites()
        #expect(try launch().people(.followingCatalogue)?.count == MapPeopleLocalCache.maxStoredPeople)
    }

    @Test func anotherAccountReadsNoneOfThem() throws {
        let cache = try launch()
        cache.store(people, in: .dock, as: cache.viewer)
        cache.waitForPendingWrites()
        #expect(try launch(as: .member(account: "acct-2", profile: "them")).people(.dock) == nil)
    }

    @Test func eachPrimaryHasItsSlots() {
        #expect(MapPeopleLocalCache.Slot.row(.friends) == .friendsRow)
        #expect(MapPeopleLocalCache.Slot.catalogue(.following) == .followingCatalogue)
        #expect(MapPeopleLocalCache.Slot.row(.pinned) == nil)
    }
}
