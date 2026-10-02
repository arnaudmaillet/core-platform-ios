import Foundation

/// Resolves an icon id to playable art — what a map marker asks for its icon
/// face, without caring where the art is made.
///
/// `AnimatedIconCatalog` answers from baked assets (`Tools/IconBaker`). The app
/// can hand the map something else that answers the same two questions — an
/// emote engine baking the very emote a post's caption carries — and the
/// markers never know the difference.
@MainActor
public protocol AnimatedIconProviding: AnyObject, Sendable {
    /// The art already in memory for `id`, or nil. Synchronous on purpose: a
    /// marker dressed from a cache hit never shows its fallback, not even for
    /// one frame.
    func cached(_ id: String) -> AnimatedIconArt?

    /// Resolves the art for `id`, loading or baking it if needed. Throws when
    /// there is none — the marker then keeps its fallback face.
    func art(for id: String) async throws -> AnimatedIconArt
}

