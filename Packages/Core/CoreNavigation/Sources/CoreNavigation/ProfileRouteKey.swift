import CoreModels

/// What a profile route is the same request as, for `RepeatPushFilter`.
///
/// A handle or a token is pushed at once and resolved by the screen (#800),
/// so until it resolves the route knows no id: a second tap on the same
/// `@handle` is keyed by the handle, and the profile it pushed is still the
/// top screen while it resolves, exactly as an id's would be.
public enum ProfileRouteKey: Hashable, Sendable {
    case id(ProfileID)
    /// Lowercased: handles are case-insensitive, `@Ada` and `@ada` are one
    /// person.
    case handle(String)
    case shareToken(String)
}

public extension AppRoute {
    /// The key a repeat of this route would share, or nil for a route that
    /// is not a profile.
    var profileRouteKey: ProfileRouteKey? {
        switch self {
        case .profile(let id, _): .id(id)
        case .profileHandle(let handle): .handle(handle.lowercased())
        case .profileShareToken(let token): .shareToken(token)
        default: nil
        }
    }
}
