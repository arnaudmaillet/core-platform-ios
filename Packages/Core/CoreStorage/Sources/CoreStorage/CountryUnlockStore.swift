import Foundation

/// The countries an ACCOUNT has unlocked on the map — not a profile's: every
/// profile of one account sees the same world.
///
/// Local and mock until the backend carries it (see
/// `dev/issues/BACKEND_COUNTRY_UNLOCKS.md`): a set of ISO alpha-2 codes per
/// account id, in `UserDefaults`. The account's home country is unlocked by
/// whoever asks (`CountryAccess`), not stored here — it is a rule, not a
/// purchase.
public final class CountryUnlockStore: @unchecked Sendable {
    public static let didChangeNotification = Notification.Name("countries.unlocks.didChange")

    private let defaults: UserDefaults
    private let lock = NSLock()

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        #if DEBUG
        // `-countries-reset`: every account back to its home country only.
        if ProcessInfo.processInfo.arguments.contains("-countries-reset") {
            for key in defaults.dictionaryRepresentation().keys where key.hasPrefix(Self.keyPrefix) {
                defaults.removeObject(forKey: key)
            }
        }
        #endif
    }

    /// The codes `accountID` has unlocked.
    public func unlocked(for accountID: String) -> Set<String> {
        lock.withLock { Set(defaults.stringArray(forKey: Self.key(accountID)) ?? []) }
    }

    /// Records `code` as unlocked for `accountID`. Returns false when it
    /// already was.
    @discardableResult
    public func unlock(_ code: String, for accountID: String) -> Bool {
        let inserted: Bool = lock.withLock {
            var codes = Set(defaults.stringArray(forKey: Self.key(accountID)) ?? [])
            let (inserted, _) = codes.insert(code.uppercased())
            if inserted { defaults.set(codes.sorted(), forKey: Self.key(accountID)) }
            return inserted
        }
        if inserted { NotificationCenter.default.post(name: Self.didChangeNotification, object: self) }
        return inserted
    }

    private static let keyPrefix = "countries.unlocked."
    private static func key(_ accountID: String) -> String { keyPrefix + accountID }
}
