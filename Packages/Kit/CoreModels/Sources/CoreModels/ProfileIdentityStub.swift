import Foundation

/// The synchronously-known slice of a profile's identity, attached to a
/// `.profile` route by surfaces that already render the user (feed cells,
/// post detail, search rows) so the destination can compose its navigation
/// chrome — title and relationship button — BEFORE the push animation starts.
/// The full profile (bio, counters, banner) still loads asynchronously behind
/// it; the stub only pre-seeds what the toolbar needs.
///
/// ⚠️ IT CARRIES WHAT THE ORIGIN SHOWS, AND NOTHING IT DOES NOT KNOW (#1858):
/// the avatar and frame its row drew, whether it knows of a banner. An
/// unknown field stays nil, never invented — a handle above all, since it
/// titles the profile.
public struct ProfileIdentityStub: Equatable, Sendable {
    /// Raw handle, no "@" sigil — the consumer applies presentation. Nil when
    /// the origin knows the person's name but not their handle (a thread, a
    /// notification row): the profile titles itself with the name until the
    /// handle is known.
    public let handle: String?
    public let displayName: String
    /// The avatar the origin drew, nil when unknown.
    public let avatarURL: URL?
    /// The avatar frame the origin drew (`avatar_frame_id`), nil for none or
    /// unknown.
    public let avatarFrameID: String?
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
    /// Whether the person has a banner, when the origin knows (#1857's
    /// `has_banner`); nil: unknown. It only shapes the destination's
    /// skeleton — what is drawn always comes from the full profile.
    public let hasBanner: Bool?

    public init(
        handle: String?,
        displayName: String,
        isFollowing: Bool? = nil,
        isSelf: Bool = false,
        avatarURL: URL? = nil,
        avatarFrameID: String? = nil,
        hasBanner: Bool? = nil
    ) {
        // An empty handle is an unknown one (an origin that had none used to
        // pass "").
        self.handle = handle.flatMap { $0.isEmpty ? nil : $0 }
        self.displayName = displayName
        self.isFollowing = isFollowing
        self.isSelf = isSelf
        self.avatarURL = avatarURL
        self.avatarFrameID = avatarFrameID
        self.hasBanner = hasBanner
    }
}

/// Where a screen reports the people it shows (#1858), so a person seen once
/// in a comment, a conversation, a search or a notification is known the
/// next time they are opened from anywhere. The shell answers it with the
/// `EntityStore`, which keeps what it already knows and only FILLS what it
/// lacks: a row's thin summary never erases a fuller one.
public protocol PeopleSightings: Sendable {
    /// People a row showed: a projection that only fills what is unknown.
    func saw(_ people: [AuthorSummary])
    /// A person's full profile, read just now: it replaces what was known.
    func loaded(_ person: AuthorSummary)
}
