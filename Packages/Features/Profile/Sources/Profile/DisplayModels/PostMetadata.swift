import Foundation

/// Pure formatting for the gallery cells' metadata line: abbreviated counts
/// and a compact post age, X-style — terse enough to sit inline without
/// stealing the row from the content.
enum PostMetadata {
    /// 1234 → "1.2K" — one shared abbreviation across the profile screen.
    static func count(_ value: Int64) -> String {
        ProfileDisplayModel.abbreviate(value)
    }

    /// The terse timeline age: "now" under a minute, then "5m" / "3h" / "2d",
    /// and a calendar date once a week old ("Jun 7", year appended when it
    /// isn't the current one).
    static func compactAge(ofMillis publishedAtMS: Int64, now: Date = Date()) -> String {
        let published = Date(timeIntervalSince1970: TimeInterval(publishedAtMS) / 1000)
        let seconds = now.timeIntervalSince(published)
        switch seconds {
        case ..<60: return "now"
        case ..<3600: return "\(Int(seconds / 60))m"
        case ..<86_400: return "\(Int(seconds / 3600))h"
        case ..<(7 * 86_400): return "\(Int(seconds / 86_400))d"
        default:
            let calendar = Calendar.current
            let formatter = DateFormatter()
            formatter.setLocalizedDateFormatFromTemplate(
                calendar.isDate(published, equalTo: now, toGranularity: .year) ? "MMM d" : "MMM d yyyy"
            )
            return formatter.string(from: published)
        }
    }
}
