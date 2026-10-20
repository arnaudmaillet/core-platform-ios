import Foundation

/// The Claim sheet's week strip (#1479): the seven days of the current UTC
/// week, Monday first, today ringed, the days the streak covers filled.
///
/// The streak is the server's `streak_days` (`WalletSnapshot.streakDays`):
/// consecutive UTC days with a claim, ending today once today has a claim,
/// yesterday while today has none yet (a streak not lost until the day
/// ends). Kept beside `WalletStore`, as `WalletStakeDays` is, because the App
/// target has no unit-test target.
public enum WalletWeek {
    public struct Day: Equatable, Sendable {
        /// The day's start, UTC.
        public let start: Date
        public let isToday: Bool
        /// A claim was made that day — the streak covers it.
        public let isClaimed: Bool
        /// After today.
        public let isFuture: Bool
    }

    /// The UTC calendar, weeks from Monday (ISO 8601).
    public static let calendar: Calendar = {
        var calendar = Calendar(identifier: .iso8601)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        return calendar
    }()

    /// The current week for a streak of `streakDays` days, today claimed or
    /// not.
    public static func days(streakDays: Int, claimedToday: Bool, now: Date) -> [Day] {
        let today = calendar.startOfDay(for: now)
        guard let week = calendar.dateInterval(of: .weekOfYear, for: now) else { return [] }
        // The streak's last day: today once claimed, else yesterday.
        let last = claimedToday ? today : calendar.date(byAdding: .day, value: -1, to: today) ?? today
        let first = calendar.date(byAdding: .day, value: -(max(0, streakDays) - 1), to: last) ?? last
        return (0..<7).compactMap { offset in
            guard let start = calendar.date(byAdding: .day, value: offset, to: week.start) else { return nil }
            let claimed = streakDays > 0 && start >= first && start <= last
            return Day(start: start, isToday: start == today, isClaimed: claimed, isFuture: start > today)
        }
    }

    /// The streak bonus a claim pays next: tomorrow's once today is claimed,
    /// today's while it is not — and whether that is tomorrow's.
    public static func nextMultiplier(streakDays: Int, claimedToday: Bool) -> (multiplier: Double, isTomorrow: Bool) {
        // A claim today extends the streak to one more day than it is now
        // (or starts it); once claimed, tomorrow's does.
        let next = max(0, streakDays) + 1
        return (WalletStore.Policy.multiplier(forStreak: next), claimedToday)
    }

    /// "×1.3": the multiplier as the chip says it — no trailing zero.
    public static func multiplierText(_ multiplier: Double) -> String {
        let rounded = (multiplier * 10).rounded() / 10
        let digits = rounded == rounded.rounded() ? 0 : 1
        return "×" + rounded.formatted(.number.precision(.fractionLength(digits)).locale(Locale(identifier: "en_US_POSIX")))
    }
}
