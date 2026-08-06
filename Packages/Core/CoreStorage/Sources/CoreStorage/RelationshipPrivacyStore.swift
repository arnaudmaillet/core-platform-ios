import Foundation

/// Which of the viewer's relationship lists they have asked to keep private.
///
/// ## ⚠️ These are preferences, not enforcement
///
/// **Nothing on the backend can express this today.** `profile.v1` has exactly
/// one privacy primitive — `SetVisibility`, which flips the *whole profile*
/// between Public and Private — and no per-list field of any kind. There is no
/// `follower_list_visibility`, no `following_list_visibility`, and no request
/// that would carry one. See `dev/BACKEND_GAPS.md` §13a.
///
/// So a flag set here is stored on **this device** and is read by **this
/// client**. It cannot govern what another person's copy of the app shows them,
/// because their copy asks the fleet, and the fleet has never been told. Any
/// screen presenting these must say so rather than implying a lock that isn't
/// there.
///
/// The type is shaped for the contract that would fix it — one flag per list,
/// keyed by the same list names the proposed fields use — so when those fields
/// land this becomes the local half of a real setting instead of a rewrite.
public struct RelationshipPrivacySettings: Codable, Equatable, Sendable {
    public var hidesFollowers: Bool
    public var hidesFollowing: Bool
    public var hidesFriends: Bool

    /// Public by default. A privacy default the viewer never chose is a
    /// setting that lies about their intent in whichever direction it guesses,
    /// and every list in this app is public until someone says otherwise.
    public init(hidesFollowers: Bool = false, hidesFollowing: Bool = false, hidesFriends: Bool = false) {
        self.hidesFollowers = hidesFollowers
        self.hidesFollowing = hidesFollowing
        self.hidesFriends = hidesFriends
    }

    public var isAnyHidden: Bool { hidesFollowers || hidesFollowing || hidesFriends }
}

/// Reads and writes `RelationshipPrivacySettings`.
///
/// Deliberately tiny and synchronous: three booleans behind a toggle have to
/// answer in the same runloop turn the switch animates in, and `UserDefaults`
/// is already the app's store for viewer-local preferences.
public final class RelationshipPrivacyStore: @unchecked Sendable {
    private let defaults: UserDefaults
    private let key = "relationshipPrivacySettings"
    /// Guards the read-modify-write in `update` — `UserDefaults` is itself
    /// thread-safe per access, which is not the same as safe across the pair.
    private let lock = NSLock()

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public var settings: RelationshipPrivacySettings {
        guard let data = defaults.data(forKey: key),
              let decoded = try? JSONDecoder().decode(RelationshipPrivacySettings.self, from: data)
        else {
            // A missing or unreadable blob is the default, not an error: this
            // is a preference, and failing closed would silently hide lists
            // the viewer never asked to hide.
            return RelationshipPrivacySettings()
        }
        return decoded
    }

    public func update(_ mutate: (inout RelationshipPrivacySettings) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        var current = settings
        mutate(&current)
        guard let data = try? JSONEncoder().encode(current) else { return }
        defaults.set(data, forKey: key)
    }
}
