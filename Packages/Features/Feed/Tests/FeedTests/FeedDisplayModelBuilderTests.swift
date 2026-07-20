import CoreModels
import Foundation
import Testing
@testable import Feed

private func entry(caption: String, publishedAt: Date = .init(timeIntervalSince1970: 0)) -> FeedEntry {
    FeedEntry(
        post: Post(
            id: PostID(UUID().uuidString),
            authorID: ProfileID("prof-1"),
            caption: caption,
            attachments: [],
            publishedAt: publishedAt
        ),
        author: AuthorSummary(id: ProfileID("prof-1"), handle: "ava", displayName: "Ava", avatarURL: nil)
    )
}

struct FeedDisplayModelBuilderTests {
    private let builder = FeedDisplayModelBuilder()
    private let now = Date(timeIntervalSince1970: 3600)

    @Test func trimsCaptionAndNilsWhenBlank() {
        #expect(builder.build([entry(caption: "  Hi.  ")], relativeTo: now)[0].caption == "Hi.")
        #expect(builder.build([entry(caption: "   ")], relativeTo: now)[0].caption == nil)
    }

    @Test func relativeTimestampsAreCompact() {
        let model = builder.build(
            [entry(caption: "x", publishedAt: Date(timeIntervalSince1970: 3600 - 180))],
            relativeTo: now
        )[0]
        // The nav-pill meta line stays COMPACT ("3m").
        #expect(model.metaText == "@ava · 3m")
    }

    /// The engaged info card's timestamp is the HUMAN-READABLE form — full
    /// words, pluralized, with days rolling into weeks past 7 days. (The
    /// formatter localizes; asserted against the test host's en_US.)
    @Test func readableTimestampUsesFullWordsAndWeeks() {
        func timestamp(_ interval: TimeInterval) -> String {
            builder.build([entry(caption: "x", publishedAt: now.addingTimeInterval(-interval))], relativeTo: now)[0]
                .timestampText
        }
        // Full words, correct pluralization…
        #expect(timestamp(5 * 86_400) == "5 days")
        #expect(timestamp(86_400) == "1 day")
        #expect(timestamp(3_600) == "1 hour")
        #expect(timestamp(5 * 60) == "5 minutes")
        // …days roll into WEEKS past 7 days (52 days → 7 weeks, not "52 days")…
        #expect(timestamp(52 * 86_400) == "7 weeks")
        #expect(timestamp(7 * 86_400) == "1 week")
        // …and the fresh edge stays "now".
        #expect(timestamp(10) == "now")
    }
}
