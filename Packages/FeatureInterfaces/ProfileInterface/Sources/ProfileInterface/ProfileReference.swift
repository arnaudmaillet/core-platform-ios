import CoreModels

/// A profile named by something other than its id — what a tapped `@handle`
/// or a scanned share link carries until the server says whose it is (#800).
public enum ProfileReference: Hashable, Sendable {
    /// A handle without its `@` (`GetProfileByHandle`, #524).
    case handle(String)
    /// A share token from a QR code or a `wynn.cn/s/<token>` link
    /// (`ResolveShareToken`, #412).
    case shareToken(String)
}

/// What the server answered about a `ProfileReference`.
public enum ProfileLookup: Equatable, Sendable {
    case found(ProfileID)
    /// No one: a renamed or deleted handle, a reset token, links switched off.
    case missing
    /// The question did not get through — offline, a timeout, a server error.
    case unavailable
}

/// Resolves a reference to the profile it names. The app owns the RPCs; the
/// profile screen asks through this once it is already on screen.
public typealias ProfileLookingUp = @Sendable (ProfileReference) async -> ProfileLookup
