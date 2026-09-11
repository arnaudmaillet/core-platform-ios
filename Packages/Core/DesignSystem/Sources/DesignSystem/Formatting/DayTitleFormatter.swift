import Foundation

/// The app's one way to name a day in a stream: "Today", "Yesterday", or a
/// localized date — the chip pinned atop each day of a conversation or a
/// comment thread.
///
/// The chat transcript builder's rules, made shared so the unified
/// conversation and a text post's comments name their days with the same
/// words: "MMMMd" within the current year, "MMMMdyyyy" otherwise. The old
/// conversation screen keeps its own copy in `ChatTranscript` until it is
/// deleted.
///
/// ⚠️ "Today" and "Yesterday" are English literals, exactly as the chat
/// transcript had them — nothing in the app is localized yet.
public enum DayTitleFormatter {
    /// `day` may be any instant in the day; only its calendar day is read.
    public static func title(for day: Date, calendar: Calendar = .current, now: Date = Date()) -> String {
        if calendar.isDate(day, inSameDayAs: now) { return "Today" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
           calendar.isDate(day, inSameDayAs: yesterday) {
            return "Yesterday"
        }
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = calendar.locale ?? .current
        let sameYear = calendar.component(.year, from: day) == calendar.component(.year, from: now)
        formatter.setLocalizedDateFormatFromTemplate(sameYear ? "MMMMd" : "MMMMdyyyy")
        return formatter.string(from: day)
    }
}
