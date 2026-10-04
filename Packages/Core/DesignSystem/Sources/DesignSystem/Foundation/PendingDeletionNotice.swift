import Foundation

/// Remembers, on this iPhone, that its holder asked to delete the account
/// (#402). A login that then reactivates the account (backend #650/#653:
/// signing back in cancels a pending deletion) is told apart from one that
/// merely ends a deactivation, so the welcome can say the deletion was
/// cancelled. The server's `LoginResponse.reactivated` doesn't say which.
public enum PendingDeletionNotice {
    static let key = "account.deletionRequestedOnThisDevice"
    /// Swappable for tests.
    nonisolated(unsafe) public static var defaults: UserDefaults = .standard

    public static func recordRequest() {
        defaults.set(true, forKey: key)
    }

    public static func clear() {
        defaults.removeObject(forKey: key)
    }

    /// True once if a deletion had been requested here; clears it.
    public static func consume() -> Bool {
        defer { clear() }
        return defaults.bool(forKey: key)
    }
}
