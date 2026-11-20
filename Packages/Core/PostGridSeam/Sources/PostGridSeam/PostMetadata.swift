import DesignSystem
import Foundation

/// Pure formatting for the grid cells' metadata line: abbreviated counts
/// and a compact post age, X-style — terse enough to sit inline without
/// stealing the row from the content.
public enum PostMetadata {
    /// 1234 → "1.2K" — one shared abbreviation across every post surface.
    public static func count(_ value: Int64) -> String {
        PostGridCount.abbreviate(value)
    }

    /// The terse timeline age: "now" under a minute, then "5m" / "3h" / "2d",
    /// and a calendar date once a week old ("Jun 7", year appended when it
    /// isn't the current one).
    public static func compactAge(ofMillis publishedAtMS: Int64, now: Date = Date()) -> String {
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

/// The app's one count abbreviation. Lives here because both the grid cells
/// and the profile header's counter row render the same numbers and must not
/// disagree about how 1234 is spelled; `ProfileDisplayModel.abbreviate`
/// delegates to it.
public enum PostGridCount {
    /// 1234 → "1.2K", 1_500_000 → "1.5M".
    ///
    /// Delegates to `CountFormatter` so a grid cell's counters and the profile
    /// header directly above them cannot disagree about how a number is
    /// spelled. ⚠️ That formatter TRUNCATES — 1,999 is "1.9K" — where this
    /// used to round it to "2K"; a counter must never overstate itself.
    public static func abbreviate(_ value: Int64) -> String {
        CountFormatter.compactString(for: value)
    }
}

