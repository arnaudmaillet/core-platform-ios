import Foundation

/// One reading of the viewer's wallet: everything the UI renders, resolved
/// at a single instant so two labels on one screen can never disagree about
/// what time it is.
public struct WalletSnapshot: Equatable, Sendable {
    /// Spendable points, never negative.
    public let balance: Int
    /// Whether tapping Claim right now would pay out.
    public let claimAvailable: Bool
    /// When the next claim unlocks. `nil` exactly when `claimAvailable` —
    /// there is nothing to count down to.
    public let nextClaimAt: Date?
    /// What the NEXT claim pays (streak multiplier and daily cap applied).
    public let claimAmount: Int
    /// Points earned via claims in the current UTC day.
    public let claimedToday: Int
    /// The day's earning ceiling — policy, surfaced so the UI never hardcodes it.
    public let dailyClaimCap: Int
    /// Consecutive UTC days with at least one claim. 0 when the chain is
    /// broken (no claim yesterday or today), not the stale last value.
    public let streakDays: Int
}

public extension WalletSnapshot {
    /// The wait toward `nextClaimAt` as (how far along, seconds left),
    /// measured against the hourly claim interval — the shape the badge's
    /// progress ring renders. Nil when nothing is pending (claim available,
    /// or no countdown at all). A capped day unlocks at UTC midnight, which
    /// can be farther than one interval away: the fraction clamps to 0
    /// until the final hour, which reads honestly as "not soon".
    var claimCountdown: (fraction: Double, remaining: TimeInterval)? {
        guard !claimAvailable, let nextClaimAt else { return nil }
        let remaining = max(0, nextClaimAt.timeIntervalSinceNow)
        guard remaining > 0 else { return nil }
        let fraction = 1 - min(1, remaining / WalletStore.Policy.claimInterval)
        return (fraction, remaining)
    }
}

/// What a claim attempt did — in-band states, not errors, because the UI
/// renders all three (the backend spec's `ClaimOutcome`, verbatim).
public enum WalletClaimOutcome: Equatable, Sendable {
    case claimed(awarded: Int)
    case tooEarly(nextClaimAt: Date)
    case dailyCapReached
}

/// What a boost spend did (the backend spec's `BoostOutcome`, minus the
/// server-only cases a local ledger cannot produce).
public enum WalletBoostOutcome: Equatable, Sendable {
    /// `spent` is what actually left the wallet — a request that would
    /// overshoot the per-target cap is CLAMPED to the cap's remainder, and
    /// every receipt (float, session tally) must be written from this
    /// number, never from the requested amount.
    case boosted(newBalance: Int, targetTotal: Int, spent: Int)
    case insufficientBalance(balance: Int)
    /// The target already holds the viewer's whole allowance
    /// (`Policy.perTargetBoostCap`); nothing changed.
    case targetCapReached(targetTotal: Int)
}

/// The viewer's point wallet and boost ledger.
///
/// **A mock with the real contract's shape, and it says so.** The backend has
/// no wallet service yet (`BACKEND_VIRTUAL_CURRENCY.md` is the ask); until it
/// does, this store IS the wallet — device-local, per-install, and trusting
/// the device clock, which are exactly the three lies the spec tells the
/// backend team to make impossible server-side. Every outcome enum here
/// mirrors the proposed wire contract, so binding to the real service is a
/// transport swap rather than a redesign.
///
/// Shape-wise this is `PostBookmarkStore`'s pattern (UserDefaults + lock,
/// injectable defaults, DEBUG seed hooks) with `ForYouUnreadStore`'s
/// injectable clock, because every rule in it is time-derived and the test
/// suite must never sleep to cross an hour boundary. Change fan-out is a
/// scoped `NotificationCenter` post (`MapFavoritesStore`'s contract): the
/// map badge, the feed rail, and the comments bar all watch ONE injected
/// instance, and posts carry `object: self` so parallel test suites with
/// their own stores never hear each other.
public final class WalletStore: @unchecked Sendable {

    /// The reward economics, in one place. These are the client-side stand-ins
    /// for values the real service will echo on `GetWallet` — surfaces read
    /// them through `WalletSnapshot` / `boostDenominations`, never directly.
    public enum Policy {
        /// A claim unlocks every hour.
        public static let claimInterval: TimeInterval = 60 * 60
        /// What an un-streaked claim pays.
        public static let baseClaimAmount = 25
        /// The most claiming can earn in one UTC day.
        public static let dailyClaimCap = 200
        /// Streak bonus: +10% per consecutive day, capped at 2×.
        public static func multiplier(forStreak streak: Int) -> Double {
            min(2.0, 1.0 + 0.1 * Double(max(0, streak - 1)))
        }
        /// A plain tap on a boost button spends this.
        public static let tapBoostAmount = 10
        /// The long-press picker's fixed options (the picker also offers
        /// "Max", computed live from the cap's remainder and the balance).
        public static let boostDenominations = [100]
        /// The most of THIS viewer's points one post (or comment) can hold
        /// — spends past it are clamped to the remainder, and a full target
        /// refuses outright.
        public static let perTargetBoostCap = 250
        /// A fresh install starts with something to spend — the boost surfaces
        /// are dead affordances on a zero balance, which is exactly the state
        /// that cannot show whether they work. Mock-only; the real wallet
        /// provisions at 0.
        public static let seededBalance = 250
    }

    private enum Key {
        static let balance = "wallet.balance"
        static let lifetimeEarned = "wallet.lifetimeEarned"
        static let lifetimeSpent = "wallet.lifetimeSpent"
        static let lastClaimAt = "wallet.lastClaimAt"
        static let claimedToday = "wallet.claimedToday"
        static let claimedTodayDay = "wallet.claimedTodayDay"
        static let streakDays = "wallet.streakDays"
        static let boostTotals = "wallet.boostTotals"
        static let seeded = "wallet.seeded"
    }

    /// Fired after every balance-affecting change, on whatever thread made
    /// it, with `object:` the store instance that changed.
    public static let didChangeNotification = Notification.Name("wallet.didChange")

    private let defaults: UserDefaults
    private let lock = NSLock()
    private let now: @Sendable () -> Date

    /// UTC everywhere, matching the spec's "UTC day" accounting — a wallet
    /// that resets on the device's local midnight would disagree with the
    /// server's ledger the day one exists.
    private static let utcCalendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    public init(defaults: UserDefaults = .standard, now: @escaping @Sendable () -> Date = { Date() }) {
        self.defaults = defaults
        self.now = now
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        // `-wallet-reset`: deterministic QA — a scripted launch always starts
        // from the seeded first-run wallet.
        if arguments.contains("-wallet-reset") {
            for key in [Key.balance, Key.lifetimeEarned, Key.lifetimeSpent, Key.lastClaimAt,
                        Key.claimedToday, Key.claimedTodayDay, Key.streakDays, Key.boostTotals,
                        Key.seeded] {
                defaults.removeObject(forKey: key)
            }
        }
        // `-wallet-balance N`: a specific balance without earning it first —
        // 0 shows the insufficient-funds path, 10000 shows wide layouts.
        if let index = arguments.firstIndex(of: "-wallet-balance"),
           index + 1 < arguments.count, let balance = Int(arguments[index + 1]) {
            defaults.set(balance, forKey: Key.balance)
            defaults.set(true, forKey: Key.seeded)
        }
        // `-wallet-claim-ready`: the claim is immediately available — the
        // pulse, the enabled button, and the payout are all reachable without
        // waiting out a real hour.
        if arguments.contains("-wallet-claim-ready") {
            defaults.removeObject(forKey: Key.lastClaimAt)
            defaults.removeObject(forKey: Key.claimedToday)
            defaults.removeObject(forKey: Key.claimedTodayDay)
        }
        // `-wallet-streak N`: an established streak whose chain is alive
        // (last claim landed yesterday), so the next claim both continues it
        // and pays the multiplied amount.
        if let index = arguments.firstIndex(of: "-wallet-streak"),
           index + 1 < arguments.count, let streak = Int(arguments[index + 1]) {
            defaults.set(streak, forKey: Key.streakDays)
            let yesterday = Self.utcCalendar.date(byAdding: .day, value: -1, to: now())!
            defaults.set(yesterday.timeIntervalSince1970, forKey: Key.lastClaimAt)
        }
        #endif
        // First run: seed the spendable starting balance, exactly once.
        if !defaults.bool(forKey: Key.seeded) {
            defaults.set(Policy.seededBalance, forKey: Key.balance)
            defaults.set(true, forKey: Key.seeded)
        }
    }

    // MARK: - Reads

    public var balance: Int {
        lock.withLock { defaults.integer(forKey: Key.balance) }
    }

    /// The wallet as of `now()` — claim availability, countdown target, next
    /// payout, and the streak the UI should show.
    public func snapshot() -> WalletSnapshot {
        lock.withLock { snapshotLocked(at: now()) }
    }

    /// Total points ever boosted into one post or comment, this device.
    public func boostTotal(forTarget targetID: String) -> Int {
        lock.withLock { boostTotalsLocked()[targetID] ?? 0 }
    }

    // MARK: - Mutations

    /// Attempts the periodic claim. `.claimed` credits the balance and
    /// advances the streak; the other outcomes change nothing.
    @discardableResult
    public func claim() -> WalletClaimOutcome {
        let outcome: WalletClaimOutcome = lock.withLock {
            let moment = now()
            let today = dayKey(for: moment)
            let claimedToday = claimedTodayLocked(today: today)
            guard claimedToday < Policy.dailyClaimCap else { return .dailyCapReached }
            if let last = lastClaimAtLocked(), moment < last.addingTimeInterval(Policy.claimInterval) {
                return .tooEarly(nextClaimAt: last.addingTimeInterval(Policy.claimInterval))
            }
            let streak = prospectiveStreakLocked(today: today)
            let awarded = min(
                Int((Double(Policy.baseClaimAmount) * Policy.multiplier(forStreak: streak)).rounded()),
                Policy.dailyClaimCap - claimedToday
            )
            defaults.set(defaults.integer(forKey: Key.balance) + awarded, forKey: Key.balance)
            defaults.set(defaults.integer(forKey: Key.lifetimeEarned) + awarded, forKey: Key.lifetimeEarned)
            defaults.set(claimedToday + awarded, forKey: Key.claimedToday)
            defaults.set(today, forKey: Key.claimedTodayDay)
            defaults.set(streak, forKey: Key.streakDays)
            defaults.set(moment.timeIntervalSince1970, forKey: Key.lastClaimAt)
            return .claimed(awarded: awarded)
        }
        if case .claimed = outcome { postDidChange() }
        return outcome
    }

    /// Spends `amount` on a post or comment — clamped to the per-target
    /// cap's remainder, refused outright on a full target. Optimistic and
    /// irreversible otherwise, like the wire contract it stands in for —
    /// no refunds.
    @discardableResult
    public func boost(targetID: String, amount: Int) -> WalletBoostOutcome {
        precondition(amount > 0, "a boost spends something")
        let outcome: WalletBoostOutcome = lock.withLock {
            var totals = boostTotalsLocked()
            let held = totals[targetID] ?? 0
            let remaining = Policy.perTargetBoostCap - held
            guard remaining > 0 else { return .targetCapReached(targetTotal: held) }
            // The cap clamps BEFORE the balance is asked: a viewer 5 short
            // of the cap taps 10 and spends 5 — a partial fill, not a
            // refusal.
            let spend = min(amount, remaining)
            let balance = defaults.integer(forKey: Key.balance)
            guard balance >= spend else { return .insufficientBalance(balance: balance) }
            let newBalance = balance - spend
            defaults.set(newBalance, forKey: Key.balance)
            defaults.set(defaults.integer(forKey: Key.lifetimeSpent) + spend, forKey: Key.lifetimeSpent)
            let targetTotal = held + spend
            totals[targetID] = targetTotal
            defaults.set(totals, forKey: Key.boostTotals)
            return .boosted(newBalance: newBalance, targetTotal: targetTotal, spent: spend)
        }
        if case .boosted = outcome { postDidChange() }
        return outcome
    }

    /// Takes back part of a target's boost — the SESSION UNDO's storage
    /// half. ⚠️ Mock-only affordance: the wire contract stays refund-free
    /// (`BACKEND_VIRTUAL_CURRENCY.md` §3), and the UI enforces the actual
    /// rule — undo exists only while the boosted post is still the active
    /// page. The store just does the arithmetic it is asked to, clamped so
    /// a stale caller can never mint points: the refund never exceeds what
    /// this target actually holds.
    ///
    /// Returns the post-refund balance and target total, or nil when the
    /// target holds nothing (nothing changed, nothing posted).
    public func undoBoost(targetID: String, amount: Int) -> (newBalance: Int, targetTotal: Int)? {
        precondition(amount > 0, "an undo takes something back")
        let result: (newBalance: Int, targetTotal: Int)? = lock.withLock {
            var totals = boostTotalsLocked()
            let held = totals[targetID] ?? 0
            let refund = min(amount, held)
            guard refund > 0 else { return nil }
            let newBalance = defaults.integer(forKey: Key.balance) + refund
            defaults.set(newBalance, forKey: Key.balance)
            defaults.set(max(0, defaults.integer(forKey: Key.lifetimeSpent) - refund), forKey: Key.lifetimeSpent)
            let remaining = held - refund
            if remaining > 0 {
                totals[targetID] = remaining
            } else {
                totals.removeValue(forKey: targetID)
            }
            defaults.set(totals, forKey: Key.boostTotals)
            return (newBalance, remaining)
        }
        if result != nil { postDidChange() }
        return result
    }

    // MARK: - Internals (lock held)

    private func snapshotLocked(at moment: Date) -> WalletSnapshot {
        let today = dayKey(for: moment)
        let claimedToday = claimedTodayLocked(today: today)
        let capped = claimedToday >= Policy.dailyClaimCap
        let intervalGate = lastClaimAtLocked().map { $0.addingTimeInterval(Policy.claimInterval) }
        let available = !capped && (intervalGate.map { moment >= $0 } ?? true)

        // The countdown target: the cap outlasts the hourly gate (UTC
        // midnight is when a capped day earns again).
        let nextClaimAt: Date?
        if available {
            nextClaimAt = nil
        } else if capped {
            nextClaimAt = Self.utcCalendar.nextDate(
                after: moment, matching: DateComponents(hour: 0), matchingPolicy: .nextTime
            )
        } else {
            nextClaimAt = intervalGate
        }

        let prospective = prospectiveStreakLocked(today: today)
        let claimAmount = max(0, min(
            Int((Double(Policy.baseClaimAmount) * Policy.multiplier(forStreak: prospective)).rounded()),
            Policy.dailyClaimCap - claimedToday
        ))
        return WalletSnapshot(
            balance: defaults.integer(forKey: Key.balance),
            claimAvailable: available,
            nextClaimAt: nextClaimAt,
            claimAmount: claimAmount,
            claimedToday: claimedToday,
            dailyClaimCap: Policy.dailyClaimCap,
            streakDays: displayStreakLocked(today: today)
        )
    }

    /// Today's claim earnings — a stored count that only counts if it was
    /// stored TODAY. The rollover is lazy (read-side), never a timer.
    private func claimedTodayLocked(today: String) -> Int {
        guard defaults.string(forKey: Key.claimedTodayDay) == today else { return 0 }
        return defaults.integer(forKey: Key.claimedToday)
    }

    private func lastClaimAtLocked() -> Date? {
        let stored = defaults.double(forKey: Key.lastClaimAt)
        return stored > 0 ? Date(timeIntervalSince1970: stored) : nil
    }

    /// The streak the NEXT claim will record: continues from yesterday,
    /// holds within today, restarts at 1 after a missed day.
    private func prospectiveStreakLocked(today: String) -> Int {
        guard let last = lastClaimAtLocked() else { return 1 }
        let stored = max(1, defaults.integer(forKey: Key.streakDays))
        let lastDay = dayKey(for: last)
        if lastDay == today { return stored }
        if lastDay == dayKey(for: Self.utcCalendar.date(byAdding: .day, value: -1, to: dayStart(of: today))!) {
            return stored + 1
        }
        return 1
    }

    /// The streak the UI shows: the stored chain while it is alive (a claim
    /// today or yesterday), 0 once it has lapsed — never the stale count.
    private func displayStreakLocked(today: String) -> Int {
        guard let last = lastClaimAtLocked() else { return 0 }
        let lastDay = dayKey(for: last)
        let yesterday = dayKey(for: Self.utcCalendar.date(byAdding: .day, value: -1, to: dayStart(of: today))!)
        guard lastDay == today || lastDay == yesterday else { return 0 }
        return max(1, defaults.integer(forKey: Key.streakDays))
    }

    private func boostTotalsLocked() -> [String: Int] {
        defaults.dictionary(forKey: Key.boostTotals) as? [String: Int] ?? [:]
    }

    /// "2026-08-14" in UTC — the ledger's day identity.
    private func dayKey(for date: Date) -> String {
        let parts = Self.utcCalendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year!, parts.month!, parts.day!)
    }

    private func dayStart(of dayKey: String) -> Date {
        let parts = dayKey.split(separator: "-").compactMap { Int($0) }
        return Self.utcCalendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))!
    }

    private func postDidChange() {
        // Outside the lock, `object: self` — unscoped posts break parallel
        // test suites (MapFavoritesStore's rule).
        NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
    }
}
