import Foundation

/// Settings → Your Activity → Time Management (#489): a daily limit and break
/// reminders, measured and kept on THIS device. Nothing here reaches a server
/// or an analytics pipeline — the time is the viewer's own business.
public struct ScreenTimeSettings: Codable, Equatable, Sendable {
    /// The daily limits offered, in minutes.
    public static let dailyLimitChoices = [15, 30, 45, 60, 90, 120, 180]
    /// The break intervals offered, in minutes of continuous use.
    public static let breakChoices = [10, 20, 30, 45, 60]
    /// How long "Remind Me Later" waits after the daily limit.
    public static let snoozeMinutes = 15

    /// Minutes per day before the limit reminder; nil = off (the default).
    public var dailyLimitMinutes: Int?
    /// Minutes of continuous use before a break reminder; nil = off (the
    /// default).
    public var breakReminderMinutes: Int?

    public init(dailyLimitMinutes: Int? = nil, breakReminderMinutes: Int? = nil) {
        self.dailyLimitMinutes = dailyLimitMinutes
        self.breakReminderMinutes = breakReminderMinutes
    }

    private enum CodingKeys: String, CodingKey { case dailyLimitMinutes, breakReminderMinutes }

    /// Every key optional, so a field added later never resets the rest.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        dailyLimitMinutes = try container.decodeIfPresent(Int.self, forKey: .dailyLimitMinutes)
        breakReminderMinutes = try container.decodeIfPresent(Int.self, forKey: .breakReminderMinutes)
    }
}

/// Seconds spent in the app per local day.
public struct ScreenTimeLedger: Codable, Equatable, Sendable {
    /// How many days are kept; older ones are dropped as new time arrives.
    public static let keptDays = 14

    /// Keyed "yyyy-MM-dd" in the device's calendar and time zone.
    public private(set) var secondsByDay: [String: TimeInterval]

    public init(secondsByDay: [String: TimeInterval] = [:]) {
        self.secondsByDay = secondsByDay
    }

    /// Adds the time between `start` and `end`, split at each local midnight
    /// so a late-night session counts toward both days.
    public mutating func record(from start: Date, to end: Date, calendar: Calendar) {
        guard end > start else { return }
        var cursor = start
        while cursor < end {
            let dayStart = calendar.startOfDay(for: cursor)
            let nextMidnight = calendar.date(byAdding: .day, value: 1, to: dayStart) ?? end
            let segmentEnd = min(end, nextMidnight)
            secondsByDay[Self.key(for: cursor, calendar: calendar), default: 0] += segmentEnd.timeIntervalSince(cursor)
            cursor = segmentEnd
        }
        prune(endingOn: end, calendar: calendar)
    }

    public func seconds(on date: Date, calendar: Calendar) -> TimeInterval {
        secondsByDay[Self.key(for: date, calendar: calendar)] ?? 0
    }

    /// The last `count` days ending with `date`'s, oldest first, days without
    /// use included as zero.
    public func lastDays(_ count: Int, endingOn date: Date, calendar: Calendar) -> [(day: Date, seconds: TimeInterval)] {
        let today = calendar.startOfDay(for: date)
        return (0..<count).reversed().compactMap { offset in
            guard let day = calendar.date(byAdding: .day, value: -offset, to: today) else { return nil }
            return (day, seconds(on: day, calendar: calendar))
        }
    }

    /// "1 hr, 5 min", "45 min", or "Less than 1 min" — how Settings and the
    /// reminders say a duration.
    public static func durationText(_ seconds: TimeInterval) -> String {
        guard seconds >= 60 else { return "Less than 1 min" }
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = seconds >= 3600 ? [.hour, .minute] : [.minute]
        formatter.unitsStyle = .short
        formatter.zeroFormattingBehavior = .dropAll
        return formatter.string(from: (seconds / 60).rounded(.down) * 60) ?? ""
    }

    public static func key(for date: Date, calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    private mutating func prune(endingOn date: Date, calendar: Calendar) {
        let kept = Set(lastDays(Self.keptDays, endingOn: date, calendar: calendar).map { Self.key(for: $0.day, calendar: calendar) })
        secondsByDay = secondsByDay.filter { kept.contains($0.key) }
    }
}

/// What the reminders have already said, so a dismissed one doesn't return
/// at once.
public struct ScreenTimeReminderState: Codable, Equatable, Sendable {
    /// "Remind Me Later" on the daily limit: not before this.
    public var limitSnoozedUntil: Date?
    /// "Ignore for Today" on the daily limit: the day it was ignored.
    public var limitIgnoredDay: String?

    public init(limitSnoozedUntil: Date? = nil, limitIgnoredDay: String? = nil) {
        self.limitSnoozedUntil = limitSnoozedUntil
        self.limitIgnoredDay = limitIgnoredDay
    }
}

public enum ScreenTimeReminder: Equatable, Sendable {
    case dailyLimit
    case takeABreak
}

/// When the next reminder is due. Pure, so every rule is pinned by tests.
public enum ScreenTimeSchedule {
    /// - Parameters:
    ///   - usedToday: today's time INCLUDING the current session up to `now`.
    ///   - continuousSince: when the current stretch of use began — the app
    ///     becoming active, or the last break reminder, whichever is later.
    public static func next(
        settings: ScreenTimeSettings,
        usedToday: TimeInterval,
        continuousSince: Date,
        now: Date,
        state: ScreenTimeReminderState,
        todayKey: String
    ) -> (reminder: ScreenTimeReminder, at: Date)? {
        var candidates: [(reminder: ScreenTimeReminder, at: Date)] = []
        if let limit = settings.dailyLimitMinutes, state.limitIgnoredDay != todayKey {
            var due = now.addingTimeInterval(max(0, TimeInterval(limit * 60) - usedToday))
            if let snoozed = state.limitSnoozedUntil, snoozed > due { due = snoozed }
            candidates.append((.dailyLimit, due))
        }
        if let interval = settings.breakReminderMinutes {
            candidates.append((.takeABreak, max(now, continuousSince.addingTimeInterval(TimeInterval(interval * 60)))))
        }
        // The earliest; on a tie the daily limit, which says more.
        return candidates.min { lhs, rhs in
            lhs.at != rhs.at ? lhs.at < rhs.at : lhs.reminder == .dailyLimit
        }
    }
}

extension Notification.Name {
    /// Posted after `ScreenTimeStore.updateSettings` writes a change.
    public static let screenTimeSettingsDidChange = Notification.Name("cn.wynn.core-platform-ios.screenTimeSettingsDidChange")
}

/// Reads and writes the settings, the ledger and the reminder state in
/// `UserDefaults`.
public final class ScreenTimeStore: @unchecked Sendable {
    public static let standard = ScreenTimeStore()

    private let defaults: UserDefaults
    private let lock = NSLock()
    private let settingsKey = "screenTime.settings"
    private let ledgerKey = "screenTime.ledger"
    private let stateKey = "screenTime.reminderState"

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public var settings: ScreenTimeSettings { read(settingsKey) ?? ScreenTimeSettings() }
    public var ledger: ScreenTimeLedger { read(ledgerKey) ?? ScreenTimeLedger() }
    public var reminderState: ScreenTimeReminderState { read(stateKey) ?? ScreenTimeReminderState() }

    public func updateSettings(_ mutate: (inout ScreenTimeSettings) -> Void) {
        lock.lock()
        var current = settings
        let before = current
        mutate(&current)
        if current != before { write(current, settingsKey) }
        lock.unlock()
        if current != before {
            NotificationCenter.default.post(name: .screenTimeSettingsDidChange, object: self)
        }
    }

    public func record(from start: Date, to end: Date, calendar: Calendar = .current) {
        lock.lock()
        var current = ledger
        current.record(from: start, to: end, calendar: calendar)
        write(current, ledgerKey)
        lock.unlock()
    }

    public func updateReminderState(_ mutate: (inout ScreenTimeReminderState) -> Void) {
        lock.lock()
        var current = reminderState
        mutate(&current)
        write(current, stateKey)
        lock.unlock()
    }

    private func read<Value: Decodable>(_ key: String) -> Value? {
        defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(Value.self, from: $0) }
    }

    private func write(_ value: some Encodable, _ key: String) {
        if let data = try? JSONEncoder().encode(value) { defaults.set(data, forKey: key) }
    }
}
