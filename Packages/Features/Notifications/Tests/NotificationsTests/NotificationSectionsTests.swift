import CoreModels
import Foundation
import Testing
@testable import Notifications

/// Sections ("New" with its "Show more", then "Earlier") and the client-side
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

    // MARK: - Sections

    @Test func newShowsTheSixMostRecentAndHoldsTheRestBehindShowMore() {
        let items = (0..<9).map { item("u\($0)", minutesAgo: Double($0)) }
            + (0..<3).map { item("r\($0)", read: true, minutesAgo: 100 + Double($0)) }
        let sections = NotificationSectionBuilder.sections(from: items.shuffled(), newExpanded: false, now: now)

        #expect(sections.map(\.kind) == [.new, .earlier])
        #expect(sections[0].rows.map(\.id) == ["u0", "u1", "u2", "u3", "u4", "u5"])
        #expect(sections[0].hiddenCount == 3)
        #expect(sections[1].rows.map(\.id) == ["r0", "r1", "r2"])
        #expect(sections[1].hiddenCount == 0)
    }

    @Test func expandedShowsEveryNewRow() {
        let items = (0..<9).map { item("u\($0)", minutesAgo: Double($0)) }
        let sections = NotificationSectionBuilder.sections(from: items, newExpanded: true, now: now)
        #expect(sections[0].rows.count == 9)
        #expect(sections[0].hiddenCount == 0)
    }

    /// "Show 1 more" is a tap for nothing: seven new rows all show.
    @Test func showMoreNeverHidesASingleRow() {
        let seven = (0..<7).map { item("u\($0)", minutesAgo: Double($0)) }
        #expect(NotificationSectionBuilder.sections(from: seven, newExpanded: false, now: now)[0].hiddenCount == 0)
        let eight = (0..<8).map { item("u\($0)", minutesAgo: Double($0)) }
        #expect(NotificationSectionBuilder.sections(from: eight, newExpanded: false, now: now)[0].hiddenCount == 2)
    }

    @Test func aSectionWithNothingInItIsLeftOut() {
        let onlyRead = [item("r0", read: true, minutesAgo: 5)]
        #expect(NotificationSectionBuilder.sections(from: onlyRead, newExpanded: false, now: now).map(\.kind) == [.earlier])
        let onlyNew = [item("u0", minutesAgo: 5)]
        #expect(NotificationSectionBuilder.sections(from: onlyNew, newExpanded: false, now: now).map(\.kind) == [.new])
        #expect(NotificationSectionBuilder.sections(from: [], newExpanded: false, now: now).isEmpty)
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
        // Eight new notifications, two of them the same like: seven rows.
        var items = (0..<7).map { item("u\($0)", minutesAgo: Double($0)) }
        items.append(item("dup", sender: "zed", post: "post-u0", minutesAgo: 50))
        let sections = NotificationSectionBuilder.sections(from: items, newExpanded: false, now: now)
        #expect(sections[0].rows.count == 7)
        #expect(sections[0].hiddenCount == 0)
        #expect(sections[0].rows[0].text.hasSuffix("and 1 other liked your post"))
    }
}
