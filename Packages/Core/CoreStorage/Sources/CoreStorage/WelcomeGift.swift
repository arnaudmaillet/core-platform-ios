import Foundation

/// The likes a guest collects before they have an account (guest mode
/// decision 11, `dev/GUEST_MODE_REPORT.md` §3.2).
///
/// A guest is handed `Policy.firstLaunch` likes the first time the app opens
/// without an account, and the day's claim amount on each of the next
/// `Policy.dailyDays` days. None of it is spendable: the balance badge shows
/// the pile, the wallet sheet's Claim button stands locked on it until the
/// guest signs up, and signing up credits it to the wallet once — once per
/// device, whoever signs in.
///
/// No countdown, no expiry, no "last chance": the pile simply stops growing
/// after the last day and waits (a dark-pattern line, DSA Art. 25).
///
/// The gift's three states, in order:
/// - unopened — no guest has opened the app on this device yet;
/// - open — a guest has, and the pile grows with the days (`lockedAmount`);
/// - settled — a member arrived and took it (`settle(into:)`), or a member
///   was here first and the device never had a guest to welcome. Final.
public final class WelcomeGift: @unchecked Sendable {
    public enum Policy {
        /// Handed on the first guest launch.
        public static let firstLaunch = 50
        /// Added once per full day after it — the claim's own base amount, so
        /// the gift grows the way a member's wallet would.
        public static let daily = WalletStore.Policy.baseClaimAmount
        /// How many daily additions there are; the pile then stops growing.
        public static let dailyDays = 3
        /// What a gift can reach: 50 + 3 × 25 = 125.
        public static var maximum: Int { firstLaunch + daily * dailyDays }
    }

    /// Fired after the gift opens or settles, with `object:` the gift. Growth
    /// with the days arrives by clock and posts nothing — see `nextGrowthAt`.
    public static let didChangeNotification = Notification.Name("welcomeGift.didChange")

    private enum Key {
        static let openedAt = "welcomeGift.openedAt"
        static let settled = "welcomeGift.settled"
    }

    private let defaults: UserDefaults
    private let lock = NSLock()
    private let now: @Sendable () -> Date

    public init(defaults: UserDefaults = .standard, now: @escaping @Sendable () -> Date = { Date() }) {
        self.defaults = defaults
        self.now = now
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        // `-welcome-gift-reset`: a fresh device, as far as the gift goes.
        if arguments.contains("-welcome-gift-reset") {
            defaults.removeObject(forKey: Key.openedAt)
            defaults.removeObject(forKey: Key.settled)
        }
        // `-welcome-gift-days N`: an open gift N days old — the grown pile
        // without waiting the days out.
        if let index = arguments.firstIndex(of: "-welcome-gift-days"),
           index + 1 < arguments.count, let days = Double(arguments[index + 1]) {
            defaults.set(now().addingTimeInterval(-days * 86_400).timeIntervalSince1970, forKey: Key.openedAt)
            defaults.removeObject(forKey: Key.settled)
        }
        #endif
    }

    // MARK: - Reads

    /// The pile waiting for a sign-up, while the gift is open; nil once it
    /// has settled or before a guest ever opened it.
    public var lockedAmount: Int? {
        lock.withLock {
            guard !defaults.bool(forKey: Key.settled), let openedAt = openedAtLocked() else { return nil }
            return Self.amount(daysOpen: fullDays(since: openedAt))
        }
    }

    /// When the pile next grows — nil when it has stopped (or isn't open).
    /// The badge re-reads then; nothing is posted.
    public var nextGrowthAt: Date? {
        lock.withLock {
            guard !defaults.bool(forKey: Key.settled), let openedAt = openedAtLocked() else { return nil }
            let days = fullDays(since: openedAt)
            guard days < Policy.dailyDays else { return nil }
            return openedAt.addingTimeInterval(Double(days + 1) * 86_400)
        }
    }

    // MARK: - Writes

    /// A guest is here: opens the gift if this device never had one. A no-op
    /// on an open or settled gift.
    public func open() {
        let opened: Bool = lock.withLock {
            guard !defaults.bool(forKey: Key.settled), openedAtLocked() == nil else { return false }
            defaults.set(now().timeIntervalSince1970, forKey: Key.openedAt)
            return true
        }
        if opened { postDidChange() }
    }

    /// A member is here: credits an open gift's pile to `wallet` and settles
    /// it, for good. Returns the amount credited — 0 when there was nothing
    /// to credit, which settles an unopened gift too: an install whose first
    /// viewer was already a member has no guest to welcome, and must not
    /// start one on a later sign-out.
    @discardableResult
    public func settle(into wallet: WalletStore) -> Int {
        let outcome: (credited: Int, changed: Bool) = lock.withLock {
            guard !defaults.bool(forKey: Key.settled) else { return (0, false) }
            let amount = openedAtLocked().map { Self.amount(daysOpen: fullDays(since: $0)) } ?? 0
            defaults.set(true, forKey: Key.settled)
            return (amount, true)
        }
        // Credit after the gift settles, so a re-entrant settle can't pay twice.
        wallet.credit(outcome.credited)
        if outcome.changed { postDidChange() }
        return outcome.credited
    }

    // MARK: - Private

    static func amount(daysOpen: Int) -> Int {
        Policy.firstLaunch + Policy.daily * min(max(daysOpen, 0), Policy.dailyDays)
    }

    private func openedAtLocked() -> Date? {
        defaults.object(forKey: Key.openedAt) == nil
            ? nil
            : Date(timeIntervalSince1970: defaults.double(forKey: Key.openedAt))
    }

    /// Whole 24-hour periods since the gift opened — a day is a day the guest
    /// waited, not a calendar boundary crossed a minute after opening.
    private func fullDays(since openedAt: Date) -> Int {
        max(0, Int(now().timeIntervalSince(openedAt) / 86_400))
    }

    private func postDidChange() {
        NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
    }
}
