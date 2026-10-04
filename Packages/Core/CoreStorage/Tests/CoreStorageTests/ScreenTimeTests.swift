import Foundation
import Testing
@testable import CoreStorage

/// Settings → Your Activity → Time Management (#489): how time is counted and
/// when the reminders come.
struct ScreenTimeTests {
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Paris")!
        return calendar
    }()

    private func date(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: minute))!
    }

    // MARK: - Ledger

    @Test func timeIsCountedPerLocalDay() {
        var ledger = ScreenTimeLedger()
        ledger.record(from: date(4, 10), to: date(4, 10, 30), calendar: calendar)
        ledger.record(from: date(4, 18), to: date(4, 18, 15), calendar: calendar)
        #expect(ledger.seconds(on: date(4, 23), calendar: calendar) == 45 * 60)
        #expect(ledger.seconds(on: date(5, 9), calendar: calendar) == 0)
    }

    /// A session across midnight counts toward both days.
    @Test func aLateSessionIsSplitAtMidnight() {
        var ledger = ScreenTimeLedger()
        ledger.record(from: date(4, 23, 50), to: date(5, 0, 20), calendar: calendar)
        #expect(ledger.seconds(on: date(4, 12), calendar: calendar) == 10 * 60)
        #expect(ledger.seconds(on: date(5, 12), calendar: calendar) == 20 * 60)
    }

    @Test func onlyTwoWeeksAreKept() {
        var ledger = ScreenTimeLedger()
        ledger.record(from: date(1, 10), to: date(1, 11), calendar: calendar)
        ledger.record(from: date(20, 10), to: date(20, 11), calendar: calendar)
        #expect(ledger.seconds(on: date(1, 12), calendar: calendar) == 0)
        #expect(ledger.secondsByDay.count == 1)
    }

    @Test func theWeekEndsTodayAndIncludesEmptyDays() {
        var ledger = ScreenTimeLedger()
        ledger.record(from: date(2, 10), to: date(2, 11), calendar: calendar)
        let week = ledger.lastDays(7, endingOn: date(4, 20), calendar: calendar)
        #expect(week.count == 7)
        #expect(calendar.isDate(week.last!.day, inSameDayAs: date(4, 0)))
        #expect(week.map(\.seconds) == [0, 0, 0, 0, 3600, 0, 0])
    }

    @Test func durationsReadNaturally() {
        #expect(ScreenTimeLedger.durationText(30) == "Less than 1 min")
        #expect(ScreenTimeLedger.durationText(45 * 60).contains("45"))
        #expect(ScreenTimeLedger.durationText(65 * 60 + 59).contains("5"))
    }

    // MARK: - Schedule

    private func next(
        _ settings: ScreenTimeSettings, used: TimeInterval, since: Date, now: Date,
        state: ScreenTimeReminderState = ScreenTimeReminderState()
    ) -> (reminder: ScreenTimeReminder, at: Date)? {
        ScreenTimeSchedule.next(
            settings: settings, usedToday: used, continuousSince: since, now: now, state: state,
            todayKey: ScreenTimeLedger.key(for: now, calendar: calendar)
        )
    }

    @Test func offMeansNoReminder() {
        #expect(next(ScreenTimeSettings(), used: 10_000, since: date(4, 9), now: date(4, 12)) == nil)
    }

    @Test func theLimitIsDueWhenTodaysTimeReachesIt() {
        let now = date(4, 12)
        let due = next(ScreenTimeSettings(dailyLimitMinutes: 60), used: 40 * 60, since: now, now: now)
        #expect(due?.reminder == .dailyLimit)
        #expect(due?.at == now.addingTimeInterval(20 * 60))
        // Already over: due now.
        #expect(next(ScreenTimeSettings(dailyLimitMinutes: 60), used: 90 * 60, since: now, now: now)?.at == now)
    }

    @Test func snoozingAndIgnoringPushTheLimitBack() {
        let now = date(4, 12)
        let settings = ScreenTimeSettings(dailyLimitMinutes: 30)
        let snoozed = ScreenTimeReminderState(limitSnoozedUntil: now.addingTimeInterval(15 * 60))
        #expect(next(settings, used: 60 * 60, since: now, now: now, state: snoozed)?.at == now.addingTimeInterval(15 * 60))
        let ignored = ScreenTimeReminderState(limitIgnoredDay: ScreenTimeLedger.key(for: now, calendar: calendar))
        #expect(next(settings, used: 60 * 60, since: now, now: now, state: ignored) == nil)
        // Ignoring is for that day only.
        #expect(next(settings, used: 60 * 60, since: date(5, 9), now: date(5, 9), state: ignored)?.reminder == .dailyLimit)
    }

    @Test func aBreakIsDueAfterContinuousUse() {
        let since = date(4, 12)
        let due = next(ScreenTimeSettings(breakReminderMinutes: 20), used: 0, since: since, now: date(4, 12, 5))
        #expect(due?.reminder == .takeABreak)
        #expect(due?.at == date(4, 12, 20))
    }

    @Test func theEarlierReminderWinsAndATieIsTheLimit() {
        let now = date(4, 12)
        let both = ScreenTimeSettings(dailyLimitMinutes: 60, breakReminderMinutes: 20)
        #expect(next(both, used: 50 * 60, since: now, now: now)?.reminder == .dailyLimit) // 10 min < 20
        #expect(next(both, used: 0, since: now, now: now)?.reminder == .takeABreak) // 20 min < 60
        #expect(next(both, used: 40 * 60, since: now, now: now)?.reminder == .dailyLimit) // both at 20 min
    }

    // MARK: - Store

    @Test func theStoreKeepsSettingsAndAnnouncesChanges() async {
        let store = ScreenTimeStore(defaults: UserDefaults(suiteName: "screen-time-\(UUID().uuidString)")!)
        #expect(store.settings == ScreenTimeSettings())
        let announced = NotificationCenter.default.notifications(named: .screenTimeSettingsDidChange, object: store)
        store.updateSettings { $0.dailyLimitMinutes = 45 }
        #expect(store.settings.dailyLimitMinutes == 45)
        var iterator = announced.makeAsyncIterator()
        #expect(await iterator.next() != nil)

        store.record(from: date(4, 10), to: date(4, 11), calendar: calendar)
        #expect(store.ledger.seconds(on: date(4, 12), calendar: calendar) == 3600)
    }
}
