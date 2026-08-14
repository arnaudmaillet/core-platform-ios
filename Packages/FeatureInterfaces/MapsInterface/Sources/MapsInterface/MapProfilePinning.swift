import CoreModels

/// Which of the map's people rails a favorite belongs to.
///
/// The map shows people in three places, and they are genuinely different
/// products rather than three views of one list:
///
/// - the **dock** — the carousel in the main filter bar, visible whatever
///   primary is selected. A pill there is a top-level filter: one tap and the
///   map is that person's posts.
/// - the **sub-filter rows** under the Friends and Following primaries, which
///   refine a primary the viewer has already chosen.
///
/// So a favorite says which of the three it wants. They are independent: the
/// same person can be docked and in neither row, in both rows and undocked,
/// or any other combination.
///
/// `friends` is the only one with a precondition — it is the map's MUTUALS
/// row, so someone the viewer merely follows can never be on it, and someone
/// who stops following back drops off it (see `MapProfilePinService`).
public enum MapFavoriteCategory: String, Sendable, CaseIterable, Hashable {
    /// The main filter bar's favorites carousel — the top-level pill.
    case dock
    /// The Following primary's sub-filter row.
    case following
    /// The Friends primary's sub-filter row. Mutuals only.
    case friends
}

/// Curating the map's pinned people — the profiles that appear as one-tap
/// filter pills in the map's favorites carousel.
///
/// ⚠️ A "pin" here is a FILTER, not a location. The map renders post pins from
/// `geo_discovery.v1`; nothing in the client or the contracts carries a
/// person's position. Pinning someone puts them a tap away in the map's people
/// rail, where selecting them narrows the map to that person's posts.
///
/// It lives behind the Maps interface because the state does: the pinned lists
/// are a Maps concern (`MapFavoritesStore`), and the one rule that makes them
/// tricky — a viewer who has never curated a rail falls back to the graph
/// behind it — needs the social graph Maps already reads. A caller that wants
/// to favorite someone from another screen should not have to know either of
/// those things, and must not import the Maps feature to find out.
///
/// Async on both sides for the same reason: answering "which rails is this
/// person on" can require resolving those fallbacks, and the first write to a
/// rail has to materialize it before it can add to or remove from it.
public protocol MapProfilePinning: Sendable {
    /// Which rails this profile currently appears in — resolving the
    /// never-curated fallbacks AND the Friends row's mutuality rule, so the
    /// answer is what the map would actually show rather than what happens to
    /// be in storage. Empty means "on no rail".
    func categories(for id: ProfileID) async -> Set<MapFavoriteCategory>

    /// Puts the profile on exactly these rails and no others. Idempotent, and
    /// each rail is written independently — asking for `[.friends]` when the
    /// profile is already on Friends and also on Following removes it from
    /// Following, which is what "exactly these" has to mean for a menu that
    /// shows the viewer both.
    func setCategories(_ categories: Set<MapFavoriteCategory>, for id: ProfileID) async
}
