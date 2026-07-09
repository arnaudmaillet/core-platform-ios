import CoreModels

/// Every navigable destination in the app, in one place.
///
/// In-app taps, universal links, and push notification payloads all parse
/// into an `AppRoute`, so cross-feature navigation has exactly one code path.
/// Features never import each other; they emit routes and the app-level
/// resolver maps them onto feature coordinators.
public enum AppRoute: Equatable, Sendable {
    case feed
    case profile(ProfileID)
    case post(PostID)
    /// The post's comments only (no post header/media) — the snap feed already
    /// shows the post full-screen, so its comment button routes here.
    case comments(PostID)
    case upload
    case conversation(ConversationID)
    /// Open (find-or-create) a direct-message thread with a profile.
    case messageUser(ProfileID)
}
