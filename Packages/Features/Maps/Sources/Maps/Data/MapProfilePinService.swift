import CoreModels
import Foundation
import MapsInterface

/// The one place that decides what "favorited on the map" means.
///
/// Both surfaces that curate the people rails go through this: the map's own
/// pill toggle and — since it is the only user-facing affordance today — a
/// profile's star button. They used to be one method on the map's view
/// controller, which was fine while the map was the only caller and wrong the
/// moment a second one appeared: the fallback rule below is subtle enough that
/// two copies of it would disagree within a release.
///
/// **The fallback rule.** Each rail in `MapFavoritesStore` is tri-state, and
/// the third state is the interesting one: `nil` means the viewer has never
/// curated that rail, and the map then shows the graph behind it — mutuals for
/// Friends, follows for Following. So a followed profile reads as favorited
/// before anyone has favorited anything, which is exactly what the map is
/// showing, and the first write has to materialize that list before it can add
/// to or remove from it. Writing a bare `[id]` instead would silently delete
/// every other person the viewer could see in the rail.
public final class MapProfilePinService: MapProfilePinning, @unchecked Sendable {
    private let store: MapFavoritesStore
    private let favorites: any MapFavoritesProviding

    /// `@unchecked Sendable` is carried by the parts: the store guards its own
    /// storage with a lock, the repository is an actor, and this type adds no
    /// mutable state of its own.
    public init(store: MapFavoritesStore, favorites: any MapFavoritesProviding) {
        self.store = store
        self.favorites = favorites
    }

    /// One rail's curated list as stored — `nil` when never curated. The map
    /// reads this synchronously to decide whether to hydrate a curated list or
    /// to show the graph; membership questions about a single profile should
    /// go through `categories(for:)`, which resolves that fallback for you.
    public func curatedProfileIDs(in category: MapFavoriteCategory) -> [ProfileID]? {
        store.pinnedProfileIDs(in: category)
    }

    public func categories(for id: ProfileID) async -> Set<MapFavoriteCategory> {
        var result: Set<MapFavoriteCategory> = []
        for category in MapFavoriteCategory.allCases where await contains(id, in: category) {
            result.insert(category)
        }
        return result
    }

    public func setCategories(_ categories: Set<MapFavoriteCategory>, for id: ProfileID) async {
        for category in MapFavoriteCategory.allCases {
            await setPinned(categories.contains(category), for: id, in: category)
        }
    }

    // MARK: - One rail at a time

    private func contains(_ id: ProfileID, in category: MapFavoriteCategory) async -> Bool {
        if let curated = store.pinnedProfileIDs(in: category) { return curated.contains(id) }
        return await fallback(for: category).contains(id)
    }

    private func setPinned(_ pinned: Bool, for id: ProfileID, in category: MapFavoriteCategory) async {
        var list: [ProfileID]
        if let curated = store.pinnedProfileIDs(in: category) {
            list = curated
        } else {
            list = await fallback(for: category)
        }
        let index = list.firstIndex(of: id)
        switch (pinned, index) {
        case (true, nil):
            list.append(id)
        case (false, .some(let index)):
            list.remove(at: index)
        default:
            // Already in the wanted state. Still worth writing when the rail
            // was never curated: the viewer has now made a choice, and leaving
            // it `nil` would let a later change to who they follow silently
            // rewrite their rail.
            guard store.pinnedProfileIDs(in: category) == nil else { return }
        }
        store.setPinned(list, in: category)
    }

    /// Who a rail shows before any curation: the graph behind it, in the
    /// repository's order and under its own cap.
    private func fallback(for category: MapFavoriteCategory) async -> [ProfileID] {
        switch category {
        case .friends: await favorites.friends().map(\.profileID)
        case .following: await favorites.following().map(\.profileID)
        }
    }
}
