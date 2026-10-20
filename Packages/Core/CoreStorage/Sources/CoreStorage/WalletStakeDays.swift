import Foundation

/// The Stakes screen's days (#1477): its stakes grouped by UTC day, newest
/// day first, newest stake first within one.
///
/// A stake is filed under the day it was PLACED while active, and the day it
/// SETTLED once settled — what each list is about. UTC, as the economy's day
/// is (the claim cap and the settlement both turn at UTC midnight).
///
/// Kept beside `WalletStore`, as `WalletStakeList` is, because the App target
/// has no unit-test target to keep it in.
public enum WalletStakeDays {
    /// One day of stakes.
    public struct Day: Equatable, Sendable {
        /// The day's start, UTC.
        public let start: Date
        public let stakes: [WalletStake]
    }

    /// The UTC calendar the days are cut in.
    public static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        return calendar
    }()

    /// `stakes` by day, newest first.
    public static func group(_ stakes: [WalletStake]) -> [Day] {
        let sorted = stakes.sorted { $0.filedAt > $1.filedAt }
        var days: [Day] = []
        for stake in sorted {
            let start = calendar.startOfDay(for: stake.filedAt)
            if let last = days.last, last.start == start {
                days[days.count - 1] = Day(start: start, stakes: last.stakes + [stake])
            } else {
                days.append(Day(start: start, stakes: [stake]))
            }
        }
        return days
    }
}

public extension WalletStake {
    /// When the stake is filed in its list: placed while active, settled once
    /// settled.
    var filedAt: Date { isSettled ? settlesAt : stakedAt }

    /// How far the stake is toward settling at `now`, 0 when placed to 1 at
    /// `settlesAt` — what its ring draws. A settled stake is 1.
    func settleProgress(at now: Date) -> Double {
        if isSettled { return 1 }
        let span = settlesAt.timeIntervalSince(stakedAt)
        guard span > 0 else { return 1 }
        return min(1, max(0, now.timeIntervalSince(stakedAt) / span))
    }
}
