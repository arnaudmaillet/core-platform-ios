import CoreModels
import Foundation
import MapsInterface

/// The one place that decides what "pinned on the map" means.
///
/// Both surfaces that curate the people rail go through this: the map's own
/// pill toggle and — since it is the only user-facing affordance today — a
/// profile's pin button. They used to be one method on the map's view
/// controller, which was fine while the map was the only caller and wrong the
/// moment a second one appeared: the fallback rule below is subtle enough that
/// two copies of it would disagree within a release.
///
/// **The fallback rule.** `MapFavoritesStore` is tri-state, and the third state
/// is the interesting one: `nil` means the viewer has never curated, and the
/// map then shows the people they FOLLOW. So a followed profile reads as
/// pinned before anyone has pinned anything — which is exactly what the map is
/// showing — and the first write has to materialize that list before it can
/// add to or remove from it. Writing a bare `[id]` instead would silently
/// delete every other person the viewer could see in the rail.
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

    /// The curated list as stored — `nil` when the viewer has never curated.
    /// The map reads this synchronously to build its rail (and falls back to
    /// `following()` itself); pin state for a single profile should go through
    /// `isPinned(_:)`, which resolves that fallback for you.
    public var pinnedProfileIDs: [ProfileID]? { store.pinnedProfileIDs }

    public func isPinned(_ id: ProfileID) async -> Bool {
        if let pinned = store.pinnedProfileIDs { return pinned.contains(id) }
        return await effectiveFallback().contains(id)
    }

    public func setPinned(_ pinned: Bool, for id: ProfileID) async {
        var list: [ProfileID]
        if let curated = store.pinnedProfileIDs {
            list = curated
        } else {
            list = await effectiveFallback()
        }
        let index = list.firstIndex(of: id)
        switch (pinned, index) {
        case (true, nil):
            list.append(id)
        case (false, .some(let index)):
            list.remove(at: index)
        default:
            // Already in the wanted state. Still worth writing when the store
            // was never curated: the viewer has now made a choice, and leaving
            // it `nil` would let a later change to who they follow silently
            // rewrite their rail.
            guard store.pinnedProfileIDs == nil else { return }
        }
        store.setPinned(list)
    }

    /// Who the rail shows before any curation: the people the viewer follows,
    /// in the repository's order and under its own cap.
    private func effectiveFallback() async -> [ProfileID] {
        await favorites.following().map(\.profileID)
    }
}
