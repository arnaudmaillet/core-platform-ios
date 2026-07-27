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
    /// Whether this profile is the signed-in viewer's own.
    ///
    /// Same bargain as `isFollowing` — something the origin already knows,
    /// carried so the destination doesn't have to discover it — but it decides
    /// more than a button title. The viewer's own profile is a *different
    /// screen*: it owns Edit Profile, the settings gear and the profile
    /// switcher, none of which a routed stranger profile is built with. Without
    /// this flag the router can only build the stranger variant, which then
    /// relabels itself to "Edit Profile" when the relationship read comes back
    /// `.me` — a visible flicker, and a button with nothing behind it.
    ///
    /// Origins that can't know leave it false: the router then takes the
    /// ordinary path, exactly as before.
    public let isSelf: Bool

    public init(
        handle: String,
        displayName: String,
        isFollowing: Bool? = nil,
        isSelf: Bool = false
    ) {
        self.handle = handle
        self.displayName = displayName
        self.isFollowing = isFollowing
        self.isSelf = isSelf
    }
}
