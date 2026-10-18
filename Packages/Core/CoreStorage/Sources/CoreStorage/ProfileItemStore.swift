import Foundation

/// A gem-shop item that changes how a profile looks (#947): bought once, for
/// good, by the ACCOUNT — every profile of the account may use it.
public enum ProfileItem: String, CaseIterable, Sendable {
    /// A muted loop from one of the viewer's own video posts, played at the
    /// top of the profile (#944; the owner, 2026-10-18).
    case videoBanner = "video-banner"

    /// What it costs, in gems (the owner, 2026-10-18: 500, once, forever).
    public var gemPrice: Int {
        switch self {
        case .videoBanner: 500
        }
    }
}

/// The profile items an ACCOUNT owns — not a profile's, as with countries
/// (`CountryUnlockStore`).
///
/// Local and mock until the backend carries ownership
/// (core-platform-backend#915 and its catalogue, #892): a set of item ids
/// per account id, in `UserDefaults`.
public final class ProfileItemStore: @unchecked Sendable {
    public static let didChangeNotification = Notification.Name("profile.items.didChange")

    private let defaults: UserDefaults
    private let lock = NSLock()

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        #if DEBUG
        // `-profile-items-reset`: every account owns nothing again.
        if ProcessInfo.processInfo.arguments.contains("-profile-items-reset") {
            for key in defaults.dictionaryRepresentation().keys where key.hasPrefix(Self.keyPrefix) {
                defaults.removeObject(forKey: key)
            }
        }
        #endif
    }

    /// The items `accountID` owns.
    public func owned(by accountID: String) -> Set<ProfileItem> {
        lock.withLock { Set(ids(accountID).compactMap(ProfileItem.init(rawValue:))) }
    }

    public func owns(_ item: ProfileItem, accountID: String) -> Bool {
        owned(by: accountID).contains(item)
    }

    /// Records `item` as owned by `accountID`. Returns false when it already
    /// was.
    @discardableResult
    public func grant(_ item: ProfileItem, to accountID: String) -> Bool {
        let inserted: Bool = lock.withLock {
            var ids = ids(accountID)
            let (inserted, _) = ids.insert(item.rawValue)
            if inserted { defaults.set(ids.sorted(), forKey: Self.key(accountID)) }
            return inserted
        }
        if inserted { NotificationCenter.default.post(name: Self.didChangeNotification, object: self) }
        return inserted
    }

    private func ids(_ accountID: String) -> Set<String> {
        Set(defaults.stringArray(forKey: Self.key(accountID)) ?? [])
    }

    private static let keyPrefix = "profile.items.owned."
    private static func key(_ accountID: String) -> String { keyPrefix + accountID }
}
