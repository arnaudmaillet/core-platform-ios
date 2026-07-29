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
    public static func abbreviate(_ value: Int64) -> String {
        let absValue = abs(value)
        switch absValue {
        case 1_000_000...:
            return trimmed(Double(value) / 1_000_000) + "M"
        case 1_000...:
            return trimmed(Double(value) / 1_000) + "K"
        default:
            return String(value)
        }
    }

    private static func trimmed(_ value: Double) -> String {
        // One decimal place, but drop a trailing ".0" (1.0K → "1K").
        let rounded = (value * 10).rounded() / 10
        if rounded == rounded.rounded() {
            return String(Int(rounded))
        }
        return String(format: "%.1f", rounded)
    }
}
