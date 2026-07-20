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
        #expect(model.metaText == "@ava · 3m")
        // The standalone timestamp (engaged info card) is the same compact
        // relative form, without the handle.
        #expect(model.timestampText == "3m")
    }

    @Test func timestampTextUsesTheDayForm() {
        let fiveDays = now.addingTimeInterval(-5 * 86_400)
        let model = builder.build([entry(caption: "x", publishedAt: fiveDays)], relativeTo: now)[0]
        #expect(model.timestampText == "5d")
    }
}
