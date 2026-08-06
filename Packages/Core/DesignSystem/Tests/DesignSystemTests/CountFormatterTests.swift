import Testing
@testable import DesignSystem

/// The app's single count spelling. Every counter on every surface routes
/// through here, so these cases are the contract the profile header, the grid
/// cells, the row context and the segment titles all share.
@Suite("Count formatter")
struct CountFormatterTests {
    @Test("Counts below a thousand are printed as they are")
    func smallCounts() {
        #expect(CountFormatter.compactString(for: 0) == "0")
        #expect(CountFormatter.compactString(for: 1) == "1")
        #expect(CountFormatter.compactString(for: 42) == "42")
        #expect(CountFormatter.compactString(for: 450) == "450")
        #expect(CountFormatter.compactString(for: 999) == "999")
    }

    @Test("Thousands abbreviate to K")
    func thousands() {
        #expect(CountFormatter.compactString(for: 1_000) == "1K")
        #expect(CountFormatter.compactString(for: 1_100) == "1.1K")
        #expect(CountFormatter.compactString(for: 1_240) == "1.2K")
        #expect(CountFormatter.compactString(for: 12_500) == "12.5K")
        #expect(CountFormatter.compactString(for: 999_000) == "999K")
    }

    @Test("Millions abbreviate to M")
    func millions() {
        #expect(CountFormatter.compactString(for: 1_000_000) == "1M")
        #expect(CountFormatter.compactString(for: 1_500_000) == "1.5M")
        #expect(CountFormatter.compactString(for: 12_300_000) == "12.3M")
        #expect(CountFormatter.compactString(for: 1_000_000_000) == "1000M")
    }

    /// The rule the whole formatter exists to enforce. Rounding would let a
    /// profile with 1,999 followers advertise "2K" — a number it has not
    /// reached — so the fraction is truncated, never rounded up.
    @Test("Truncates rather than rounding, so a count is never overstated")
    func truncatesRatherThanRounding() {
        #expect(CountFormatter.compactString(for: 1_999) == "1.9K")
        #expect(CountFormatter.compactString(for: 1_990) == "1.9K")
        #expect(CountFormatter.compactString(for: 1_099) == "1K")
        #expect(CountFormatter.compactString(for: 999_999) == "999.9K")
        #expect(CountFormatter.compactString(for: 1_999_999) == "1.9M")
    }

    /// The boundaries either side of each threshold, where an off-by-one in
    /// the switch would show up as "1000" instead of "1K".
    @Test("Threshold boundaries")
    func boundaries() {
        #expect(CountFormatter.compactString(for: 999) == "999")
        #expect(CountFormatter.compactString(for: 1_000) == "1K")
        #expect(CountFormatter.compactString(for: 999_999) == "999.9K")
        #expect(CountFormatter.compactString(for: 1_000_000) == "1M")
    }

    /// Counts should never be negative, but the formatter is handed `Int64`
    /// from the wire and must not produce nonsense if one arrives. Truncation
    /// is toward zero, so the magnitude shown is never larger than the real one.
    @Test("Negatives keep their sign and never grow in magnitude")
    func negatives() {
        #expect(CountFormatter.compactString(for: -5) == "-5")
        #expect(CountFormatter.compactString(for: -1_500) == "-1.5K")
        #expect(CountFormatter.compactString(for: -1_999) == "-1.9K")
        #expect(CountFormatter.compactString(for: -2_000_000) == "-2M")
    }

    @Test("The Int overload and the sugar agree with the Int64 one")
    func overloadsAgree() {
        #expect(CountFormatter.compactString(for: Int(1_240)) == "1.2K")
        #expect(1_240.formattedCompact() == "1.2K")
        #expect(Int64(1_500_000).formattedCompact() == "1.5M")
    }

    /// The reason this type exists: the row context used to carry its own
    /// abbreviation, and the grid cells another that rounded. Both now route
    /// here, and this pins them together.
    @Test("Row context spells counts the same way")
    func rowContextDelegates() {
        #expect(ProfileRowContext.followerCount(1_999).label == "1.9K followers")
        #expect(ProfileRowContext.followerCount(450).label == "450 followers")
    }
}
