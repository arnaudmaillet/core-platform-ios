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
        // `-countries-reset`: every account back to a fresh install — its
        // home country, plus whatever a seed grants again on this launch
        // (`seedUnlocks`; the app's mock seed is skipped with
        // `-countries-no-seed`).
        if ProcessInfo.processInfo.arguments.contains("-countries-reset") {
            for key in defaults.dictionaryRepresentation().keys
            where key.hasPrefix(Self.keyPrefix) || key.hasPrefix(Self.seedKeyPrefix) {
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

    /// Takes `code` back from `accountID`. Returns false when it was not
    /// unlocked. A country a seed granted stays locked afterwards: a seed
    /// never grants the same code twice (`seedUnlocks`).
    @discardableResult
    public func relock(_ code: String, for accountID: String) -> Bool {
        let removed: Bool = lock.withLock {
            var codes = Set(defaults.stringArray(forKey: Self.key(accountID)) ?? [])
            guard codes.remove(code.uppercased()) != nil else { return false }
            defaults.set(codes.sorted(), forKey: Self.key(accountID))
            return true
        }
        if removed { NotificationCenter.default.post(name: Self.didChangeNotification, object: self) }
        return removed
    }

    /// Unlocks `codes` for `accountID` as if bought — ONCE per code, ever.
    ///
    /// Safe to call on every launch: the codes a seed has granted are
    /// remembered beside the unlocks, so a relaunch grants only codes no
    /// earlier seed carried (a seed that grows still reaches an existing
    /// install) and never re-grants one the account has since lost. What
    /// the account unlocked itself is never touched. Returns the codes this
    /// call newly unlocked.
    @discardableResult
    public func seedUnlocks(_ codes: Set<String>, for accountID: String) -> Set<String> {
        let granted: Set<String> = lock.withLock {
            let wanted = Set(codes.map { $0.uppercased() })
            let seeded = Set(defaults.stringArray(forKey: Self.seedKey(accountID)) ?? [])
            let fresh = wanted.subtracting(seeded)
            guard !fresh.isEmpty else { return [] }
            var unlocked = Set(defaults.stringArray(forKey: Self.key(accountID)) ?? [])
            let granted = fresh.subtracting(unlocked)
            unlocked.formUnion(fresh)
            defaults.set(unlocked.sorted(), forKey: Self.key(accountID))
            defaults.set(seeded.union(fresh).sorted(), forKey: Self.seedKey(accountID))
            return granted
        }
        if !granted.isEmpty { NotificationCenter.default.post(name: Self.didChangeNotification, object: self) }
        return granted
    }

    private static let keyPrefix = "countries.unlocked."
    /// The codes a seed already granted, per account — kept apart from the
    /// unlocks so losing a country never makes the seed grant it again.
    private static let seedKeyPrefix = "countries.seeded."
    private static func key(_ accountID: String) -> String { keyPrefix + accountID }
    private static func seedKey(_ accountID: String) -> String { seedKeyPrefix + accountID }
}
