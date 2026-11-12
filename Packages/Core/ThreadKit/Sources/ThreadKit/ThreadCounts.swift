import Foundation

/// A thread's counts as the rows and the subtitles print them (#2380): "843",
/// "1.2k". Moved from `SnapSubtitleView`, which keeps answering through it.
///
/// ⚠️ It ROUNDS ("2.0k" for 1,999), where the app's rule (`CountFormatter`)
/// truncates: a divergence #2390 settles, kept as is by this move.
public enum ThreadCounts {
    public static func countText(_ count: Int) -> String {
        count >= 1000 ? String(format: "%.1fk", Double(count) / 1000) : String(count)
    }
}
