import Foundation
import Testing
@testable import CoreStorage

/// The Claim sheet's week strip and streak chip (#1479).
struct WalletWeekTests {
    /// October 2026 at `hour` UTC; the 19th is a Monday, the 25th a Sunday.
    private static func at(day: Int, _ hour: Int = 12) -> Date {
        var parts = DateComponents()
        parts.year = 2026
        parts.month = 10
        parts.day = day
        parts.hour = hour
        return WalletWeek.calendar.date(from: parts)!
    }

    /// Wednesday the 21st, a 3-day streak claimed today: Mon, Tue and Wed
    /// filled, Wed ringed, Thu to Sun ahead.
    @Test func aStreakFillsItsDaysOfTheWeek() {
        let days = WalletWeek.days(streakDays: 3, claimedToday: true, now: Self.at(day: 21))
        #expect(days.count == 7)
        #expect(days.first?.start == Self.at(day: 19, 0), "Monday first")
        #expect(days.map(\.isClaimed) == [true, true, true, false, false, false, false])
        #expect(days.map(\.isToday) == [false, false, true, false, false, false, false])
        #expect(days.map(\.isFuture) == [false, false, false, true, true, true, true])
    }

    /// Not claimed yet today, the streak ends yesterday: today is ringed and
    /// empty.
    @Test func unclaimedTodayTheStreakEndsYesterday() {
        let days = WalletWeek.days(streakDays: 2, claimedToday: false, now: Self.at(day: 21))
        #expect(days.map(\.isClaimed) == [true, true, false, false, false, false, false])
        #expect(days[2].isToday && !days[2].isClaimed)
    }

    /// A streak longer than the week fills it up to today; one that began
    /// last week fills from Monday.
    @Test func aStreakFromLastWeekFillsFromMonday() {
        let days = WalletWeek.days(streakDays: 12, claimedToday: true, now: Self.at(day: 22))
        #expect(days.map(\.isClaimed) == [true, true, true, true, false, false, false])
    }

    @Test func noStreakNoFilledDay() {
        let days = WalletWeek.days(streakDays: 0, claimedToday: false, now: Self.at(day: 25))
        #expect(days.allSatisfy { !$0.isClaimed })
        #expect(days.last?.isToday == true, "Sunday closes the week")
    }

    /// Just after midnight UTC on Monday, a new week: only today, claimed.
    @Test func theWeekTurnsAtUTCMidnightOnMonday() {
        let days = WalletWeek.days(streakDays: 8, claimedToday: true, now: Self.at(day: 26, 0))
        #expect(days.first?.start == Self.at(day: 26, 0))
        #expect(days.map(\.isClaimed) == [true, false, false, false, false, false, false])
    }

    /// The chip: tomorrow's bonus once today is claimed, today's before;
    /// capped at ×2.
    @Test func theChipSaysTheNextBonus() {
        let claimed = WalletWeek.nextMultiplier(streakDays: 3, claimedToday: true)
        #expect(claimed.isTomorrow)
        #expect(WalletWeek.multiplierText(claimed.multiplier) == "×1.3")
        let unclaimed = WalletWeek.nextMultiplier(streakDays: 3, claimedToday: false)
        #expect(!unclaimed.isTomorrow)
        #expect(WalletWeek.multiplierText(WalletWeek.nextMultiplier(streakDays: 0, claimedToday: false).multiplier) == "×1")
        #expect(WalletWeek.multiplierText(WalletWeek.nextMultiplier(streakDays: 30, claimedToday: true).multiplier) == "×2")
    }
}
