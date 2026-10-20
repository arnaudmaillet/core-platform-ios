import Foundation
import Testing
@testable import CoreStorage

/// The Stakes screen's days and rings (#1477).
struct WalletStakeDaysTests {
    /// 2026-10-20 at `hour`:`minute` UTC.
    private static func at(_ hour: Int, _ minute: Int = 0, day: Int = 20) -> Date {
        var parts = DateComponents()
        parts.year = 2026
        parts.month = 10
        parts.day = day
        parts.hour = hour
        parts.minute = minute
        return WalletStakeDays.calendar.date(from: parts)!
    }

    private static func stake(
        _ id: String, placed: Date, settles: Date, outcome: WalletStake.Outcome? = nil
    ) -> WalletStake {
        WalletStake(targetID: id, amount: 10, stakedAt: placed, settlesAt: settles, outcome: outcome)
    }

    /// Active stakes by the UTC day they were placed, newest day first and
    /// newest first within a day.
    @Test func activeStakesGroupByTheDayTheyWerePlaced() {
        let stakes = [
            Self.stake("a", placed: Self.at(9), settles: Self.at(9, day: 21)),
            Self.stake("b", placed: Self.at(23, 30, day: 19), settles: Self.at(23, day: 20)),
            Self.stake("c", placed: Self.at(18), settles: Self.at(18, day: 21)),
            Self.stake("d", placed: Self.at(0, 10), settles: Self.at(0, 10, day: 21)),
        ]
        let days = WalletStakeDays.group(stakes)
        #expect(days.map(\.start) == [Self.at(0), Self.at(0, day: 19)])
        #expect(days.map { $0.stakes.map(\.targetID) } == [["c", "a", "d"], ["b"]])
    }

    /// The day is UTC's, whatever the device's zone: 23:30 UTC on the 19th
    /// is the 19th even where it is already the 20th.
    @Test func theDayIsUTCs() {
        let late = Self.stake("late", placed: Self.at(23, 30, day: 19), settles: Self.at(23, 30, day: 20))
        #expect(WalletStakeDays.group([late]).first?.start == Self.at(0, day: 19))
    }

    /// A settled stake is filed under the day it settled.
    @Test func settledStakesGroupByTheDayTheySettled() {
        let stakes = [
            Self.stake("old", placed: Self.at(8, day: 17), settles: Self.at(8, day: 18), outcome: .rewarded),
            Self.stake("new", placed: Self.at(8, day: 18), settles: Self.at(7, day: 20), outcome: .notRewarded),
        ]
        let days = WalletStakeDays.group(stakes)
        #expect(days.map { $0.stakes.map(\.targetID) } == [["new"], ["old"]])
        #expect(days.map(\.start) == [Self.at(0), Self.at(0, day: 18)])
    }

    @Test func noStakesNoDays() {
        #expect(WalletStakeDays.group([]).isEmpty)
    }

    /// The ring: 0 when placed, half way at the middle, full at settlement,
    /// clamped either side; settled is full.
    @Test func theRingFollowsTheTimeToSettle() {
        let stake = Self.stake("s", placed: Self.at(0), settles: Self.at(12))
        #expect(stake.settleProgress(at: Self.at(0)) == 0)
        #expect(stake.settleProgress(at: Self.at(6)) == 0.5)
        #expect(stake.settleProgress(at: Self.at(9)) == 0.75)
        #expect(stake.settleProgress(at: Self.at(12)) == 1)
        #expect(stake.settleProgress(at: Self.at(13)) == 1)
        #expect(stake.settleProgress(at: Self.at(0, day: 19)) == 0)
        let settled = Self.stake("t", placed: Self.at(0), settles: Self.at(12), outcome: .rewarded)
        #expect(settled.settleProgress(at: Self.at(1)) == 1)
        let instant = Self.stake("u", placed: Self.at(5), settles: Self.at(5))
        #expect(instant.settleProgress(at: Self.at(4)) == 1)
    }
}
