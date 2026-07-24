import CoreModels
import Foundation
import Testing
@testable import Chat

struct ChatTranscriptTests {
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        calendar.locale = Locale(identifier: "en_US_POSIX")
        return calendar
    }()

    /// Noon UTC, well clear of day boundaries.
    private let now = Date(timeIntervalSince1970: 86_400 * 20_000 + 43_200)

    private func message(
        _ id: String, sender: String = "them", minutesAgo: Double, mine: Bool = false
    ) -> MessageDisplayModel {
        MessageDisplayModel(message: ChatMessage(
            id: id,
            senderID: ProfileID(sender),
            body: "body-\(id)",
            createdAt: now.addingTimeInterval(-minutesAgo * 60),
            isMine: mine
        ))
    }

    private func build(_ messages: [MessageDisplayModel]) -> [TranscriptSection] {
        ChatTranscript.build(from: messages, calendar: calendar, now: now)
    }

    // MARK: - Run grouping

    @Test func consecutiveSameSenderMessagesFormARun() {
        let sections = build([
            message("a", minutesAgo: 10),
            message("b", minutesAgo: 9),
            message("c", minutesAgo: 8),
            message("d", sender: "me", minutesAgo: 7, mine: true)
        ])
        #expect(sections.count == 1)
        #expect(sections[0].rows.map(\.position) == [.first, .middle, .last, .single])
    }

    @Test func senderChangeBreaksARun() {
        let sections = build([
            message("a", minutesAgo: 10),
            message("b", sender: "me", minutesAgo: 9, mine: true),
            message("c", minutesAgo: 8)
        ])
        #expect(sections[0].rows.map(\.position) == [.single, .single, .single])
    }

    @Test func gapBeyondFiveMinutesBreaksARun() {
        let sections = build([
            message("a", minutesAgo: 20),
            message("b", minutesAgo: 14),  // 6 min later: new run
            message("c", minutesAgo: 10)   // 4 min later: same run
        ])
        #expect(sections[0].rows.map(\.position) == [.single, .first, .last])
    }

    // MARK: - Day sections

    @Test func daysSplitIntoSectionsWithRelativeTitles() {
        let sections = build([
            message("old", minutesAgo: 60 * 24 * 40),
            message("yesterday", minutesAgo: 60 * 24),
            message("today", minutesAgo: 10)
        ])
        #expect(sections.count == 3)
        #expect(sections[1].day.title == "Yesterday")
        #expect(sections[2].day.title == "Today")
        // A plain date, not a relative word — and no year within the same year.
        #expect(!sections[0].day.title.isEmpty)
        #expect(!sections[0].day.title.contains("day"))
    }

    @Test func runsNeverSpanDayBoundaries() {
        // Same sender, 3 minutes apart, straddling midnight.
        let midnight = calendar.startOfDay(for: now)
        let sections = build([
            message("before", minutesAgo: now.timeIntervalSince(midnight) / 60 + 2),
            message("after", minutesAgo: now.timeIntervalSince(midnight) / 60 - 1)
        ])
        #expect(sections.count == 2)
        #expect(sections[0].rows.map(\.position) == [.single])
        #expect(sections[1].rows.map(\.position) == [.single])
    }

    // MARK: - Rows

    @Test func rowsCarryFormattedTimeAndAlignment() {
        let sections = build([message("a", sender: "me", minutesAgo: 0, mine: true)])
        let row = sections[0].rows[0]
        #expect(row.isMine)
        // Whitespace before AM/PM varies by ICU version (narrow no-break
        // space since iOS 17) — assert the stable parts only.
        #expect(row.timeText.hasPrefix("12:00"))
        #expect(row.timeText.hasSuffix("PM"))
        #expect(row.body == "body-a")
    }

    @Test func emptyInputProducesNoSections() {
        #expect(build([]).isEmpty)
    }

    // MARK: - Quoted replies

    private func reply(_ id: String, to targetID: String, mine: Bool = true, minutesAgo: Double) -> MessageDisplayModel {
        MessageDisplayModel(message: ChatMessage(
            id: id,
            senderID: ProfileID(mine ? "me" : "them"),
            body: "body-\(id)",
            createdAt: now.addingTimeInterval(-minutesAgo * 60),
            isMine: mine,
            replyToID: targetID
        ))
    }

    @Test func replyResolvesQuoteFromReferencedMessage() {
        let sections = ChatTranscript.build(
            from: [message("orig", minutesAgo: 10), reply("ans", to: "orig", minutesAgo: 1)],
            peerName: "Ava", calendar: calendar, now: now
        )
        let rows = sections.flatMap(\.rows)
        let quote = rows.first { $0.id == "ans" }?.quote
        #expect(quote?.messageID == "orig")
        #expect(quote?.author == "Ava")        // original is the peer's
        #expect(quote?.snippet == "body-orig")
        #expect(rows.first { $0.id == "orig" }?.quote == nil) // non-reply carries none
    }

    @Test func replyToOwnMessageLabelsQuoteYou() {
        let mineOriginal = message("orig", sender: "me", minutesAgo: 10, mine: true)
        let sections = ChatTranscript.build(
            from: [mineOriginal, reply("ans", to: "orig", mine: false, minutesAgo: 1)],
            peerName: "Ava", calendar: calendar, now: now
        )
        #expect(sections.flatMap(\.rows).first { $0.id == "ans" }?.quote?.author == "You")
    }

    @Test func replyToMissingOriginalHasNoQuote() {
        let sections = ChatTranscript.build(
            from: [reply("ans", to: "ghost", minutesAgo: 1)],
            peerName: "Ava", calendar: calendar, now: now
        )
        #expect(sections.flatMap(\.rows).first?.quote == nil)
    }
}
