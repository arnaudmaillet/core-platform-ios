import Foundation

/// Points the device-local stores at whoever is here (#2376): the app's one
/// `StorageScope`, and the teen flag that belongs to one account.
///
/// The app drives it as the viewer changes — `enter(account:)` from
/// `AppCoordinator.render` (through `AppContainer.enterStorageScope`), before
/// anything writes for the new viewer, and `profileResolved(account:profile:)`
/// as the viewer session resolves the account's active profile or a switch
/// changes it. It lives here rather than in the app so that
/// `ViewerIsolationTests` runs the very code the app runs.
///
/// ⚠️ NOTHING IS WIPED: the stores are keyed per profile or per account
/// (`StorageScope`), and keys are what keep viewers apart. The one exception
/// is `TeenProtections`, whose flag is the device's: it is dropped the moment
/// another account (or nobody) is here, and the account's own read records it
/// again (`AccountRepository.currentAccount`).
@MainActor
public final class ViewerStorageBinding {
    private let scope: StorageScope
    private let teenProtections: TeenProtections

    public init(scope: StorageScope, teenProtections: TeenProtections) {
        self.scope = scope
        self.teenProtections = teenProtections
    }

    /// `account` signed in, or nobody (nil: a guest). Returns whether the
    /// scope moved to a member account it did not hold — the app then reads
    /// the account, which records its age bracket. The same account keeps the
    /// profile it already resolved, and returns false.
    @discardableResult
    public func enter(account: String?) -> Bool {
        guard let account else {
            scope.owner = .guest
            teenProtections.clear()
            return false
        }
        if case .member(account, _) = scope.owner { return false }
        scope.owner = .member(account: account, profile: nil)
        // Another account's flag never protects (or restricts) this one: it
        // goes until this account's read records its own. The same account
        // coming back at a cold start keeps its flag, so a teen is protected
        // from the first frame.
        teenProtections.clear(unlessRecordedFor: account)
        return true
    }

    /// The viewer session resolved `account`'s active profile, or a switch
    /// changed it. Ignored unless the scope holds that account: an answer
    /// for an account that has since left changes nothing.
    public func profileResolved(account: String, profile: String) {
        guard case .member(account, _) = scope.owner else { return }
        scope.owner = .member(account: account, profile: profile)
    }
}
