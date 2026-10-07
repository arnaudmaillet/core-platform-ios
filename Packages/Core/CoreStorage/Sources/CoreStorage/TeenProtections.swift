import Foundation

/// Teen protections (#401) the app applies on THIS device for an account aged
/// 13–17. The server already starts such a profile private, with messages
/// from followers, location hidden, sensitive content at Less and quiet hours
/// from 22:00 to 07:00; what it does not do is held here:
///
/// - **no purchases**: neither buying with gems nor spending them;
/// - **a 60-minute daily limit**, set once per account on this device, which
///   the teen can change or turn off like anyone else's (Time Management).
///
/// The age comes from `account.v1`'s age bracket, recorded whenever the app
/// reads the account; a guest, or an account with no date of birth, is not
/// treated as a teen.
public final class TeenProtections: @unchecked Sendable {
    public static let shared = TeenProtections()

    /// The daily limit a teen account starts with on a device, in minutes.
    public static let defaultDailyLimitMinutes = 60

    private let defaults: UserDefaults
    private let screenTime: ScreenTimeStore
    private let lock = NSLock()
    private let minorKey = "teen.isMinor"
    private let accountKey = "teen.account"
    private func limitAppliedKey(_ account: String) -> String { "teen.dailyLimitApplied.\(account)" }

    public init(defaults: UserDefaults = .standard, screenTime: ScreenTimeStore = .standard) {
        self.defaults = defaults
        self.screenTime = screenTime
    }

    /// Whether the signed-in account is 13–17.
    public var isMinor: Bool {
        lock.withLock { defaults.bool(forKey: minorKey) }
    }

    /// Purchases are off for 13–17.
    public var restrictsPurchases: Bool { isMinor }

    /// What the app learnt reading the account. A teen account's first
    /// record on this device sets the daily limit, unless one is already set;
    /// a later change by the teen is never undone.
    public func record(account: String, isMinor: Bool) {
        let applyLimit: Bool = lock.withLock {
            defaults.set(isMinor, forKey: minorKey)
            defaults.set(account, forKey: accountKey)
            guard isMinor, !defaults.bool(forKey: limitAppliedKey(account)) else { return false }
            defaults.set(true, forKey: limitAppliedKey(account))
            return true
        }
        if applyLimit {
            screenTime.updateSettings { settings in
                if settings.dailyLimitMinutes == nil { settings.dailyLimitMinutes = Self.defaultDailyLimitMinutes }
            }
        }
    }

    /// Signed out, or a guest: nobody here is known to be a teen.
    public func clear() {
        lock.withLock {
            defaults.set(false, forKey: minorKey)
            defaults.removeObject(forKey: accountKey)
        }
    }
}
