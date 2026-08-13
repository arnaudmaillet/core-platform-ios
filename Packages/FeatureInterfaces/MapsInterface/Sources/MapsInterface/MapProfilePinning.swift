import CoreModels

/// Which of the map's people rails a favorite belongs to.
///
/// The map's primaries already split people this way — Friends narrows to
/// mutuals, Following to everyone the viewer follows — so a favorite has to
/// say which of those two rails it wants to appear in. A mutual can be in
/// both, in one, or in neither; someone the viewer merely follows can only
/// ever be in `following`, because they are not a friend to begin with.
public enum MapFavoriteCategory: String, Sendable, CaseIterable, Hashable {
    /// Mutual follows — the Friends primary.
    case friends
    /// Everyone the viewer follows, mutual or not — the Following primary.
    case following
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
    /// never-curated fallbacks, so the answer is what the map would actually
    /// show rather than what happens to be in storage. Empty means "on no
    /// rail".
    func categories(for id: ProfileID) async -> Set<MapFavoriteCategory>

    /// Puts the profile on exactly these rails and no others. Idempotent, and
    /// each rail is written independently — asking for `[.friends]` when the
    /// profile is already on Friends and also on Following removes it from
    /// Following, which is what "exactly these" has to mean for a menu that
    /// shows the viewer both.
    func setCategories(_ categories: Set<MapFavoriteCategory>, for id: ProfileID) async
}
