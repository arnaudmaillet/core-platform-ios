import Foundation
import Testing
@testable import DesignSystem

/// The short relative age the conversation list, the comment rows and the
/// notifications share (#811). These strings are exactly what the three
/// private copies printed, boundaries included: each rung truncates, and the
/// boundary itself belongs to the next rung.
@Suite("Relative age formatter")
struct RelativeAgeFormatterTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func age(_ seconds: TimeInterval, rollsUpToWeeks: Bool = true) -> String {
        RelativeAgeFormatter.short(from: now.addingTimeInterval(-seconds), to: now, rollsUpToWeeks: rollsUpToWeeks)
    }

    @Test("Under a minute is now")
    func underAMinute() {
        #expect(age(0) == "now")
        #expect(age(59) == "now")
        #expect(age(59.9) == "now")
    }

    @Test("Minutes, from 60 s to 59 m")
    func minutes() {
        #expect(age(60) == "1m")
        #expect(age(119) == "1m")
        #expect(age(120) == "2m")
        #expect(age(3_599) == "59m")
    }

    @Test("Hours, from 1 h to 23 h")
    func hours() {
        #expect(age(3_600) == "1h")
        #expect(age(7_199) == "1h")
        #expect(age(86_399) == "23h")
    }

    @Test("Days, from 1 d to 6 d")
    func days() {
        #expect(age(86_400) == "1d")
        #expect(age(6 * 86_400) == "6d")
        #expect(age(604_799) == "6d")
    }

    @Test("Weeks from 7 days, never rolling further")
    func weeks() {
        #expect(age(604_800) == "1w")
        #expect(age(2 * 604_800 - 1) == "1w")
        #expect(age(2 * 604_800) == "2w")
        #expect(age(52 * 86_400) == "7w")
        #expect(age(400 * 86_400) == "57w")
    }

    /// A clock running ahead of the server's must not count backwards.
    @Test("A future date reads now")
    func futureDate() {
        #expect(age(-300) == "now")
    }

    /// The feed meta line's register: it keeps counting days.
    @Test("Without weeks, days keep counting")
    func withoutWeeks() {
        #expect(age(59, rollsUpToWeeks: false) == "now")
        #expect(age(3_599, rollsUpToWeeks: false) == "59m")
        #expect(age(86_399, rollsUpToWeeks: false) == "23h")
        #expect(age(604_799, rollsUpToWeeks: false) == "6d")
        #expect(age(604_800, rollsUpToWeeks: false) == "7d")
        #expect(age(52 * 86_400, rollsUpToWeeks: false) == "52d")
        #expect(age(-300, rollsUpToWeeks: false) == "now")
    }
}
