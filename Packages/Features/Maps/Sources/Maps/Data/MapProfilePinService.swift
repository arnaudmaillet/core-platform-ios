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
/// Friends, follows for Following and for the dock. So a followed profile reads as favorited
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

    /// Replaces one rail's list wholesale — what the full-list sheet commits
    /// when the viewer finishes arranging a row.
    ///
    /// No materialization needed and none wanted: the sheet hands back the
    /// complete row, so this IS the curated list. Going through the per-person
    /// path instead would re-resolve a fallback the sheet has already
    /// superseded.
    public func setCuratedList(_ ids: [ProfileID], in category: MapFavoriteCategory) {
        store.setPinned(ids, in: category)
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
            // A non-mutual cannot be written onto the Friends row at all —
            // the rule is enforced on the way in as well as on the way out, so
            // a stale caller cannot leave an entry that only becomes visible
            // if the two of them later become friends.
            if category == .friends, categories.contains(.friends), await !isMutual(id) { continue }
            await setPinned(categories.contains(category), for: id, in: category)
        }
    }

    // MARK: - One rail at a time

    private func contains(_ id: ProfileID, in category: MapFavoriteCategory) async -> Bool {
        // The Friends row is the map's MUTUALS row, and it enforces that on
        // the way out rather than by editing the stored list: someone who
        // stops following back drops off the row, and returns to it if they
        // follow back again. Deleting them instead would quietly destroy a
        // choice the viewer made, and could not be undone by the graph.
        if category == .friends, await !isMutual(id) { return false }
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
    /// repository's order and under its own cap. The dock's fallback is the
    /// following list — what the carousel has always shown, so an install that
    /// never curates sees exactly what it saw before the rails existed.
    private func fallback(for category: MapFavoriteCategory) async -> [ProfileID] {
        switch category {
        case .friends: await favorites.friends().map(\.profileID)
        case .following, .dock: await favorites.following().map(\.profileID)
        }
    }

    /// Whether they follow back right now, per the graph — the Friends row's
    /// precondition. Read at the moment it is needed rather than remembered,
    /// because the whole point is that it changes underneath a curated list.
    private func isMutual(_ id: ProfileID) async -> Bool {
        await favorites.friends().contains { $0.profileID == id }
    }
}
