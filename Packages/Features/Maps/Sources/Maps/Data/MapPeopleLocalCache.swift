import CacheKit
import CoreModels
import Foundation
import LocalStore
import MapsInterface

/// The map's people on the device (#1776), in the LocalStore: the dock's
/// pills and the Friends / Following sub-filter rows open on their last
/// people at the next launch, offline included, then revalidate in place —
/// they were fetched at every load and kept for the session only.
///
/// One list per slot (`map.people.<slot>`), each a versioned
/// `map.person` record per pill, in the slot's order. The viewer's own graph,
/// so `retained`; the store's viewer scope keeps it the viewer's, and a
/// sign-out or a switch wipes it with the other device caches.
///
/// Reads are synchronous (the screen's first frame); writes go to a serial
/// queue, each as the viewer captured BEFORE its network call.
final class MapPeopleLocalCache: Sendable {
    static let entityType = "map.person"
    static let format = 1
    /// A catalogue is the whole graph behind a rail; past this many, the
    /// rest is the network's.
    static let maxStoredPeople = 200

    /// What a stored list stands for.
    enum Slot: String, CaseIterable, Sendable {
        case dock
        case friendsRow, followingRow
        case friendsCatalogue, followingCatalogue

        static func row(_ primary: MapFilter) -> Slot? {
            switch primary {
            case .friends: .friendsRow
            case .following: .followingRow
            default: nil
            }
        }

        static func catalogue(_ primary: MapFilter) -> Slot? {
            switch primary {
            case .friends: .friendsCatalogue
            case .following: .followingCatalogue
            default: nil
            }
        }
    }

    private let list: LocalRecordList<Record>

    init(store: LocalStore) {
        list = LocalRecordList(store: store, entityType: Self.entityType, format: Self.format, name: "map-people")
    }

    /// Who a list is being fetched for, captured before the fetch.
    var viewer: LocalStoreViewer? { list.viewer }

    /// The slot's people as last read, in order; nil when none are stored.
    func people(_ slot: Slot) -> [MapFavorite]? {
        list.read(Self.listKey(slot))?.records.compactMap(\.favorite)
    }

    func store(_ people: [MapFavorite], in slot: Slot, as viewer: LocalStoreViewer?) {
        list.write(
            people.prefix(Self.maxStoredPeople).map { (id: $0.profileID.rawValue, record: Record($0)) },
            to: Self.listKey(slot), as: viewer, lifetime: LocalStorePolicy.profileLifetime
        )
    }

    static func listKey(_ slot: Slot) -> String { "map.people.\(slot.rawValue)" }

    /// Waits for every write queued so far. Tests only.
    func waitForPendingWrites() {
        list.waitForPendingWrites()
    }

    struct Record: Codable, Equatable {
        var profileID: String
        var title: String
        var avatarURL: URL?
        var handle: String?

        init(_ favorite: MapFavorite) {
            profileID = favorite.profileID.rawValue
            title = favorite.title
            avatarURL = favorite.avatarURL
            handle = favorite.handle
        }

        var favorite: MapFavorite {
            MapFavorite(profileID: ProfileID(profileID), title: title, avatarURL: avatarURL, handle: handle)
        }
    }
}
