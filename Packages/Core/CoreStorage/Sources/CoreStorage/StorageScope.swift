import Foundation

/// Whose identity the device-local stores are holding (guest mode §6.6,
/// `dev/GUEST_MODE_REPORT.md`).
///
/// Saves, follows, drafts and money express an identity, so each store keeps
/// them per PROFILE or per ACCOUNT: a second person signing in on this device
/// sees their own pile, never the last person's, and a guest sees none. Device
/// preferences (recent searches, display settings, the welcome gift) are not
/// scoped and stay with the device.
///
/// Stores ask for their keys at the moment they read or write
/// (`profileKey(_:)`, `accountKey(_:)`), so every instance — however many a
/// screen made with `init()` — follows the viewer without being rebuilt. The
/// app sets `owner` as the viewer changes (`AppCoordinator.render`, and
/// `AppContainer` once the active profile resolves).
///
/// ⚠️ NOTHING IS WIPED on sign-out: with no server holding these lists yet,
/// wiping would lose them for good. Keying is what keeps them apart.
///
/// **What was there before keys were scoped** (the original, unscoped key) is
/// adopted once, by the first member who reads it: an install upgrading keeps
/// its saves, its drafts and its wallet under the account that wrote them,
/// and a guest never inherits them.
public final class StorageScope: @unchecked Sendable {
    public enum Owner: Equatable, Sendable {
        /// Nobody has said yet: the original, unscoped keys. What a test or a
        /// preview gets, and what the app holds only until its first render.
        case unscoped
        case guest
        /// `profile` is nil until the account's active profile is known; the
        /// profile's keys fall back to the account's meanwhile.
        case member(account: String, profile: String?)
    }

    /// The app's one scope.
    public static let shared = StorageScope()

    /// Posted after `owner` changes, with the scope as the object: stores that
    /// hold a copy in memory (`PostDraftStore`) re-read, and the wallet seeds
    /// a member's first wallet.
    public static let didChangeNotification = Notification.Name("storageScope.didChange")

    private let lock = NSLock()
    private var _owner: Owner

    public init(owner: Owner = .unscoped) {
        _owner = owner
    }

    public var owner: Owner {
        get { lock.withLock { _owner } }
        set {
            let changed: Bool = lock.withLock {
                guard _owner != newValue else { return false }
                _owner = newValue
                return true
            }
            if changed { NotificationCenter.default.post(name: Self.didChangeNotification, object: self) }
        }
    }

    /// Whether the viewer may hold a wallet of their own: anyone but a guest,
    /// whose likes are the welcome gift's (`WelcomeGift`), not a wallet's.
    public var holdsWallet: Bool { owner != .guest }

    /// `base`, as the active PROFILE's key, adopting the unscoped value the
    /// first time a member's profile reads it (see the type's note).
    public func profileKey(_ base: String, adoptingLegacyIn defaults: UserDefaults) -> String {
        let key = profileKey(base)
        if case .member(_, _?) = owner { adoptLegacy(base, into: key, defaults: defaults) }
        return key
    }

    /// `base`, as the ACCOUNT's key, adopting the unscoped value the first
    /// time a member reads it.
    public func accountKey(_ base: String, adoptingLegacyIn defaults: UserDefaults) -> String {
        let key = accountKey(base)
        if case .member = owner { adoptLegacy(base, into: key, defaults: defaults) }
        return key
    }

    private func adoptLegacy(_ base: String, into key: String, defaults: UserDefaults) {
        guard key != base, let legacy = defaults.object(forKey: base) else { return }
        if defaults.object(forKey: key) == nil { defaults.set(legacy, forKey: key) }
        defaults.removeObject(forKey: base)
    }

    /// `base`, as the active PROFILE's key.
    public func profileKey(_ base: String) -> String {
        switch owner {
        case .unscoped: base
        case .guest: base + "@guest"
        case .member(let account, nil): base + "@a:" + account
        case .member(_, let profile?): base + "@p:" + profile
        }
    }

    /// `base`, as the ACCOUNT's key — whichever of its profiles is active.
    public func accountKey(_ base: String) -> String {
        switch owner {
        case .unscoped: base
        case .guest: base + "@guest"
        case .member(let account, _): base + "@a:" + account
        }
    }
}
