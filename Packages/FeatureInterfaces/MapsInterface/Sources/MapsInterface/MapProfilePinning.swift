import CoreModels

/// Curating the map's pinned people — the profiles that appear as one-tap
/// filter pills in the map's favorites carousel.
///
/// ⚠️ A "pin" here is a FILTER, not a location. The map renders post pins from
/// `geo_discovery.v1`; nothing in the client or the contracts carries a
/// person's position. Pinning someone puts them a tap away in the map's people
/// rail, where selecting them narrows the map to that person's posts.
///
/// It lives behind the Maps interface because the state does: the pinned list
/// is a Maps concern (`MapFavoritesStore`), and the one rule that makes it
/// tricky — a viewer who has never curated falls back to the people they
/// follow — needs the social graph Maps already reads. A caller that wants to
/// pin someone from another screen should not have to know either of those
/// things, and must not import the Maps feature to find out.
///
/// Async on both sides for the same reason: answering "is this person pinned"
/// can require resolving that fallback, and the first write has to materialize
/// it before it can add to or remove from it.
public protocol MapProfilePinning: Sendable {
    /// Whether this profile is currently pinned — resolving the
    /// never-curated fallback, so the answer is what the map would actually
    /// show rather than what happens to be in storage.
    func isPinned(_ id: ProfileID) async -> Bool

    /// Pins or unpins the profile. Idempotent: pinning a pinned profile (or
    /// unpinning an absent one) leaves the list exactly as it was, so a caller
    /// racing its own optimistic state cannot duplicate an entry.
    func setPinned(_ pinned: Bool, for id: ProfileID) async
}
