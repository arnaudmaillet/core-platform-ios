/// The synchronously-known slice of a profile's identity, attached to a
/// `.profile` route by surfaces that already render the user (feed cells,
/// post detail, search rows) so the destination can compose its navigation
/// chrome — title and relationship button — BEFORE the push animation starts.
/// The full profile (bio, counters, banner) still loads asynchronously behind
/// it; the stub only pre-seeds what the toolbar needs.
public struct ProfileIdentityStub: Equatable, Sendable {
    /// Raw handle, no "@" sigil — the consumer applies presentation.
    public let handle: String
    public let displayName: String
    /// The viewer's follow state, when the origin surface knows it; nil means
    /// unknown, and the relationship button stays hidden until the async
    /// relationship read resolves.
    public let isFollowing: Bool?

    public init(handle: String, displayName: String, isFollowing: Bool? = nil) {
        self.handle = handle
        self.displayName = displayName
        self.isFollowing = isFollowing
    }
}
