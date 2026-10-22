import CoreModels
import Foundation
import Testing
@testable import Notifications

/// Sections by date ("New", "Yesterday", … each with its "Show more") and the client-side
/// folding of rows about the same thing.
struct NotificationSectionsTests {
    private let now = Date(timeIntervalSince1970: 100_000)

    private func item(
        _ id: String,
        action: NotificationItem.Action = .reaction,
        sender: String? = nil,
        others: Int = 0,
        samples: [NotificationActor] = [],
        post: String? = nil,
        read: Bool = false,
        minutesAgo: Double
    ) -> NotificationItem {
        let senderID = sender ?? "prof-\(id)"
        return NotificationItem(
            id: id, action: action, senderID: ProfileID(senderID), senderName: "Name \(senderID)",
            senderAvatarURL: URL(string: "https://example.com/\(senderID).jpg"),
            otherSenderCount: others, sampleSenders: samples,
            postSubjectID: PostID(post ?? "post-\(id)"), isRead: read,
            createdAt: now.addingTimeInterval(-minutesAgo * 60)
        )
    }

    private func actor(_ id: String) -> NotificationActor {
        NotificationActor(id: ProfileID(id), name: "Name \(id)", avatarURL: nil)
    }

    // MARK: - Sections (#1571: by date)

    /// UTC, so a day is the same day wherever the suite runs.
    private var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private func sections(
        _ items: [NotificationItem], expanded: Set<NotificationSection.Kind> = [], now: Date? = nil
    ) -> [NotificationSection] {
        NotificationSectionBuilder.sections(from: items, expanded: expanded, now: now ?? self.now, calendar: utc)
    }

    /// `now` is 03:46 UTC: whole days back from it.
    private func daysAgo(_ days: Double) -> Double { days * 24 * 60 }

    @Test func eachRowFallsInItsDaysSection() {
        // 03:46 UTC: 3 minutes ago is today; 4 hours ago is yesterday.
        let items = [
            item("today", minutesAgo: 3),
            item("yesterday", minutesAgo: 4 * 60),
            item("week", minutesAgo: daysAgo(5)),
            item("month", minutesAgo: daysAgo(20)),
            item("year", minutesAgo: daysAgo(200)),
            item("older", minutesAgo: daysAgo(400)),
        ]
        let built = sections(items.shuffled())
        #expect(built.map(\.kind) == [.new, .yesterday, .lastWeek, .lastMonth, .lastYear, .older])
        #expect(built.map(\.title) == ["New", "Yesterday", "Last week", "Last month", "Last year", "Older"])
        #expect(built.map { $0.rows.map(\.id) } == [["today"], ["yesterday"], ["week"], ["month"], ["year"], ["older"]])
    }

    /// The boundaries are whole calendar days, on the viewer's calendar.
    @Test func theBoundariesAreCalendarDays() {
        let calendar = utc
        let noon = calendar.date(from: DateComponents(year: 2026, month: 10, day: 22, hour: 12))!
        func kind(daysBack: Int, hour: Int) -> NotificationSection.Kind {
            let day = calendar.date(byAdding: .day, value: -daysBack, to: calendar.startOfDay(for: noon))!
            let date = calendar.date(byAdding: .hour, value: hour, to: day)!
            return NotificationSection.Kind.of(date, now: noon, calendar: calendar)
        }
        #expect(kind(daysBack: 0, hour: 0) == .new, "midnight today")
        #expect(kind(daysBack: 1, hour: 23) == .yesterday, "23:00 yesterday")
        #expect(kind(daysBack: 2, hour: 0) == .lastWeek)
        #expect(kind(daysBack: 7, hour: 23) == .lastWeek)
        #expect(kind(daysBack: 8, hour: 0) == .lastMonth)
        #expect(kind(daysBack: 30, hour: 23) == .lastMonth)
        #expect(kind(daysBack: 31, hour: 0) == .lastYear)
        #expect(kind(daysBack: 365, hour: 23) == .lastYear)
        #expect(kind(daysBack: 366, hour: 0) == .older)
        #expect(NotificationSection.Kind.of(noon.addingTimeInterval(600), now: noon, calendar: calendar) == .new,
                "a date ahead of now (a skewed clock) is today's")
    }

    /// The day follows the viewer's time zone: the same instant is today in
    /// one and yesterday in another.
    @Test func theDayFollowsTheTimeZone() {
        var tokyo = Calendar(identifier: .gregorian)
        tokyo.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        // now = 03:46 UTC = 12:46 in Tokyo; 4 hours ago = 23:46 UTC yesterday, 08:46 in Tokyo today.
        let date = now.addingTimeInterval(-4 * 3600)
        #expect(NotificationSection.Kind.of(date, now: now, calendar: utc) == .yesterday)
        #expect(NotificationSection.Kind.of(date, now: now, calendar: tokyo) == .new)
    }

    /// Read or not, a row stays in its day: seeing it never moves it.
    @Test func readStateNeverMovesARow() {
        let built = sections([item("seen", read: true, minutesAgo: 2), item("unseen", minutesAgo: 1)])
        #expect(built.map(\.kind) == [.new])
        #expect(Set(built[0].rows.map(\.id)) == ["seen", "unseen"])
    }

    /// Six rows per section before "Show more", and twelve in the LAST one.
    @Test func sixPerSectionAndMoreInTheLast() {
        let items = (0..<9).map { item("t\($0)", minutesAgo: Double($0)) }
            + (0..<15).map { item("y\($0)", minutesAgo: 4 * 60 + Double($0)) }
        let built = sections(items.shuffled())
        #expect(built.map(\.kind) == [.new, .yesterday])
        #expect(built[0].rows.map(\.id) == ["t0", "t1", "t2", "t3", "t4", "t5"])
        #expect(built[0].hiddenCount == 3)
        #expect(built[1].rows.count == 12, "the last section shows twelve")
        #expect(built[1].hiddenCount == 3)
    }

    @Test func expandingASectionShowsAllOfItAlone() {
        let items = (0..<9).map { item("t\($0)", minutesAgo: Double($0)) }
            + (0..<15).map { item("y\($0)", minutesAgo: 4 * 60 + Double($0)) }
        let built = sections(items, expanded: [.new])
        #expect(built[0].rows.count == 9)
        #expect(built[0].hiddenCount == 0)
        #expect(built[1].hiddenCount == 3, "expanding New expanded Yesterday")
    }

    /// "Show 1 more" is a tap for nothing: one row past the limit all show.
    @Test func showMoreNeverHidesASingleRow() {
        let yesterday = [item("y", minutesAgo: 4 * 60)]
        let seven = (0..<7).map { item("t\($0)", minutesAgo: Double($0)) } + yesterday
        #expect(sections(seven)[0].hiddenCount == 0)
        let eight = (0..<8).map { item("t\($0)", minutesAgo: Double($0)) } + yesterday
        #expect(sections(eight)[0].hiddenCount == 2)
        let thirteen = (0..<13).map { item("t\($0)", minutesAgo: Double($0)) }
        #expect(sections(thirteen)[0].hiddenCount == 0, "the last section: twelve plus one all show")
    }

    @Test func aSectionWithNothingInItIsLeftOut() {
        #expect(sections([item("w", minutesAgo: daysAgo(4))]).map(\.kind) == [.lastWeek])
        #expect(sections([]).isEmpty)
    }

    // MARK: - Folding

    @Test func likesOnTheSamePostFoldIntoOneRowLedByTheMostRecent() {
        let items = [
            item("a", sender: "ava", post: "post-1", minutesAgo: 30),
            item("b", sender: "ben", post: "post-1", minutesAgo: 2),
            item("c", sender: "cleo", post: "post-1", minutesAgo: 10)
        ]
        let grouped = NotificationGrouping.grouped(items)
        #expect(grouped.count == 1)
        let row = grouped[0]
        #expect(row.id == "b")
        #expect(row.senderName == "Name ben")
        #expect(row.otherSenderCount == 2)
        #expect(row.sampleSenders.map(\.id.rawValue) == ["cleo", "ava"])

        let model = NotificationDisplayModel(item: row, now: now)
        #expect(model.text == "Name ben and 2 others liked your post")
        #expect(model.faces.count == 2)
        #expect(model.timeText == "2m")
    }

    @Test func differentActionsPostsOrReadStatesStayApart() {
        let items = [
            item("a", action: .reaction, post: "post-1", minutesAgo: 1),
            item("b", action: .comment, post: "post-1", minutesAgo: 2),
            item("c", action: .reaction, post: "post-2", minutesAgo: 3),
            item("d", action: .reaction, post: "post-1", read: true, minutesAgo: 4)
        ]
        #expect(NotificationGrouping.grouped(items).map(\.id) == ["a", "b", "c", "d"])
    }

    /// The same person in both rows is one person, not two.
    @Test func foldingCountsDistinctPeople() {
        let items = [
            item("a", sender: "ava", post: "post-1", minutesAgo: 1),
            item("b", sender: "ava", post: "post-1", minutesAgo: 5)
        ]
        let row = NotificationGrouping.grouped(items)[0]
        #expect(row.otherSenderCount == 0)
        #expect(NotificationDisplayModel(item: row, now: now).faces.count == 1)
    }

    /// A server-collapsed row keeps the people it counted without naming.
    @Test func foldingKeepsTheServersUnnamedSenders() {
        let items = [
            item("a", sender: "ava", others: 4, samples: [actor("ben")], post: "post-1", minutesAgo: 1),
            item("b", sender: "cleo", post: "post-1", minutesAgo: 5)
        ]
        let row = NotificationGrouping.grouped(items)[0]
        // ava, ben, cleo named + 3 unnamed from the first row.
        #expect(row.otherSenderCount == 5)
    }

    @Test func foldsBeforeSectioningSoShowMoreCountsRows() {
        // Eight of today's notifications, two of them the same like: seven rows.
        var items = (0..<7).map { item("u\($0)", minutesAgo: Double($0)) }
        items.append(item("dup", sender: "zed", post: "post-u0", minutesAgo: 50))
        items.append(item("y", minutesAgo: 4 * 60))
        let built = sections(items)
        #expect(built[0].rows.count == 7)
        #expect(built[0].hiddenCount == 0)
        #expect(built[0].rows[0].text.hasSuffix("and 1 other liked your post"))
    }

    /// Folding stays inside a section: the same like today and yesterday are
    /// two rows, in two sections.
    @Test func foldingNeverCrossesSections() {
        let items = [
            item("today", sender: "ava", post: "post-x", minutesAgo: 3),
            item("yesterday", sender: "ben", post: "post-x", minutesAgo: 4 * 60),
        ]
        let built = sections(items)
        #expect(built.map(\.kind) == [.new, .yesterday])
        #expect(built.allSatisfy { $0.rows.count == 1 })
    }
}
