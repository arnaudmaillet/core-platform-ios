import CoreModels

/// Every navigable destination in the app, in one place.
///
/// In-app taps, universal links, and push notification payloads all parse
/// into an `AppRoute`, so cross-feature navigation has exactly one code path.
/// Features never import each other; they emit routes and the app-level
/// resolver maps them onto feature coordinators.
public enum AppRoute: Equatable, Sendable {
    case feed
    /// The Messages inbox, a primary root tab. The category selects which of
    /// the inbox's paged surfaces lands active — `.all` is the plain
    /// "open Messages" case.
    case messages(MessagesCategory)
    /// A user's profile. Origins that already render the user (feed cells,
    /// search rows) attach a `ProfileIdentityStub` so the destination can
    /// compose its navigation chrome before the push animates; `nil` when the
    /// origin knows nothing beyond the id (deep links, debug args).
    case profile(ProfileID, stub: ProfileIdentityStub?)
    case post(PostID)
    /// The post's comments only (no post header/media) — the snap feed already
    /// shows the post full-screen, so its comment button routes here.
    case comments(PostID)
    case upload
    case conversation(ConversationID)
    /// Open a direct-message thread with a profile, finding or creating the
    /// conversation as needed. The stub carries whatever identity the origin
    /// was already rendering — a picker row, a suggestion, a map pin — so the
    /// thread's header is correct on the push's first frame instead of after a
    /// lookup; `nil` when the origin knows only the id (deep links, debug args).
    case messageUser(ProfileID, stub: ProfileIdentityStub?)
    /// Compose a new message: the contact-selection flow. The inbox's compose
    /// button emits this; the resolver owns what it presents.
    case newMessage
}
