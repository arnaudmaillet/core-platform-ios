import Foundation

/// The app's one short relative age: "now", "5m", "3h", "2d", "1w" (#811).
///
/// The conversation list, the comment rows and the notifications each carried
/// an identical private copy of this ladder; one copy drifting would have made
/// the same instant read differently on two tabs. The feed's meta line keeps
/// counting days instead of rolling up to weeks, which is what
/// `rollsUpToWeeks: false` is for.
///
/// Each rung is the elapsed time TRUNCATED to its unit, with the boundary
/// belonging to the next rung: 59.9 s is "now", 60 s is "1m", 3,599 s is
/// "59m", 3,600 s is "1h", 604,799 s is "6d", 604,800 s is "1w". A date in
/// the future (a clock running ahead of the server's) reads "now".
///
/// No formatter object and no allocation beyond the returned string: it runs
/// in cell configuration.
///
/// ⚠️ Not `PostMetadata.compactAge`, which switches to a calendar date past a
/// week for a grid tile — a different register on purpose.
public enum RelativeAgeFormatter {
    /// `rollsUpToWeeks: false` keeps counting days past a week ("52d").
    public static func short(from date: Date, to now: Date, rollsUpToWeeks: Bool = true) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        switch seconds {
        case ..<60: return "now"
        case ..<3600: return "\(Int(seconds / 60))m"
        case ..<86_400: return "\(Int(seconds / 3600))h"
        case ..<604_800: return "\(Int(seconds / 86_400))d"
        default:
            return rollsUpToWeeks ? "\(Int(seconds / 604_800))w" : "\(Int(seconds / 86_400))d"
        }
    }
}
