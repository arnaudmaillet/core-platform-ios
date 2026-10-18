import Foundation

/// The History tab's groups (#1344, the owner 2026-10-17): the posts viewed,
/// newest first, under the time they were viewed — "Today", "Yesterday",
/// "This Week", "Last Week", "This Month", "Last Month", then each month by
/// name (with its year once it is another year's). A view recorded before the
/// times were kept goes under "Earlier", at the end.
///
/// A group is a TITLE and a COUNT over the posts in order, not the posts: the
/// page keeps its one list, and the groups say where each title stands.
public nonisolated struct HistoryGroup: Equatable, Sendable {
    public let title: String
    public let count: Int

    public init(title: String, count: Int) {
        self.title = title
        self.count = count
    }
}

nonisolated enum HistoryDayGroups {
    static let earlierTitle = "Earlier"

    /// The groups for `dates` (one per post, in order, newest first), as of
    /// `now`. Posts of one title are one group even if they are not
    /// consecutive — an undated view in the middle of dated ones joins
    /// "Earlier" — so the caller moves undated posts to the end first.
    static func groups(for dates: [Date?], now: Date, calendar: Calendar = .current) -> [HistoryGroup] {
        var titles: [String] = []
        var counts: [String: Int] = [:]
        for date in dates {
            let day = title(for: date, now: now, calendar: calendar)
            if counts[day] == nil { titles.append(day) }
            counts[day, default: 0] += 1
        }
        return titles.map { HistoryGroup(title: $0, count: counts[$0] ?? 0) }
    }

    /// The title a post viewed at `date` goes under.
    static func title(for date: Date?, now: Date, calendar: Calendar = .current) -> String {
        guard let date else { return earlierTitle }
        if calendar.isDate(date, inSameDayAs: now) || date > now { return "Today" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
           calendar.isDate(date, inSameDayAs: yesterday) { return "Yesterday" }
        if calendar.isDate(date, equalTo: now, toGranularity: .weekOfYear) { return "This Week" }
        if let lastWeek = calendar.date(byAdding: .weekOfYear, value: -1, to: now),
           calendar.isDate(date, equalTo: lastWeek, toGranularity: .weekOfYear) { return "Last Week" }
        if calendar.isDate(date, equalTo: now, toGranularity: .month) { return "This Month" }
        if let lastMonth = calendar.date(byAdding: .month, value: -1, to: now),
           calendar.isDate(date, equalTo: lastMonth, toGranularity: .month) { return "Last Month" }
        var style = Date.FormatStyle(date: .omitted, time: .omitted, locale: calendar.locale ?? .current, calendar: calendar)
            .month(.wide)
        if !calendar.isDate(date, equalTo: now, toGranularity: .year) { style = style.year() }
        return date.formatted(style)
    }
}
