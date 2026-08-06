import Foundation

/// The app's one way to spell a count.
///
/// Follower counts, view counts, likes, segment titles and row context all show
/// the same kind of number, often on the same screen — a profile header sits
/// directly above a grid whose cells carry their own counters. Two spellings of
/// 1,999 in that space ("1.9K" and "2K") read as two different numbers, so this
/// is deliberately the only implementation and everything else delegates here.
///
/// **Truncating, not rounding.** 1,999 is "1.9K", never "2K": the abbreviation
/// must never claim more than the count it came from. Rounding up is how a
/// profile ends up advertising a thousand followers it does not have. For
/// negatives the truncation is toward zero, on the same principle — the
/// magnitude shown is never larger than the real one.
public enum CountFormatter {
    /// 0 → "0", 1_240 → "1.2K", 1_999 → "1.9K", 1_000_000 → "1M".
    public static func compactString(for value: Int64) -> String {
        let magnitude = abs(value)
        switch magnitude {
        case 1_000_000...:
            return trimmed(Double(value) / 1_000_000) + "M"
        case 1_000...:
            return trimmed(Double(value) / 1_000) + "K"
        default:
            return String(value)
        }
    }

    public static func compactString(for value: Int) -> String {
        compactString(for: Int64(value))
    }

    /// One decimal place, truncated, with a trailing ".0" dropped so 1,000
    /// reads "1K" rather than "1.0K".
    private static func trimmed(_ value: Double) -> String {
        let truncated = (value * 10).rounded(.towardZero) / 10
        return truncated == truncated.rounded()
            ? String(Int(truncated))
            : String(format: "%.1f", truncated)
    }
}

public extension BinaryInteger {
    /// `1_240.formattedCompact()` → "1.2K". Sugar over
    /// ``CountFormatter/compactString(for:)-(Int64)`` for call sites that read
    /// better with the number first.
    func formattedCompact() -> String {
        CountFormatter.compactString(for: Int64(self))
    }
}
