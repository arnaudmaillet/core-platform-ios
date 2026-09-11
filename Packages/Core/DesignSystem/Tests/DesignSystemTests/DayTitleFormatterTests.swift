import Foundation
import Testing
@testable import DesignSystem

/// The day chip's words. Pinned to a fixed calendar, zone and locale, so the
/// cases read the same on any machine and at any hour.
@Suite("Day title formatter")
struct DayTitleFormatterTests {
    private static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        calendar.locale = Locale(identifier: "en_US")
        return calendar
    }

    /// 2025-09-11 12:00 UTC.
    private static let now = Date(timeIntervalSince1970: 1_757_592_000)

    private func title(_ day: Date) -> String {
        DayTitleFormatter.title(for: day, calendar: Self.calendar, now: Self.now)
    }

    @Test("The current day is Today, whatever the hour")
    func today() {
        #expect(title(Self.now) == "Today")
        #expect(title(Self.now.addingTimeInterval(-11 * 3600)) == "Today")
    }

    @Test("The day before is Yesterday")
    func yesterday() {
        #expect(title(Self.now.addingTimeInterval(-86_400)) == "Yesterday")
    }

    @Test("Earlier this year drops the year")
    func earlierThisYear() {
        // 2025-03-05 12:00 UTC.
        #expect(title(Date(timeIntervalSince1970: 1_741_176_000)) == "March 5")
    }

    @Test("Another year spells the year out")
    func anotherYear() {
        // 2024-03-05 12:00 UTC.
        #expect(title(Date(timeIntervalSince1970: 1_709_640_000)) == "March 5, 2024")
    }
}
