import CoreModels
import Foundation
import Testing
@testable import Feed

private func entry(caption: String, media: (Int, Int)? = nil, publishedAt: Date = .init(timeIntervalSince1970: 0)) -> FeedEntry {
    FeedEntry(
        post: Post(
            id: PostID(UUID().uuidString),
            authorID: ProfileID("prof-1"),
            caption: caption,
            attachments: media.map { [MediaAttachment(url: URL(string: "mock://m"), thumbnailURL: nil, mimeType: "image/png", pixelWidth: $0.0, pixelHeight: $0.1)] } ?? [],
            publishedAt: publishedAt
        ),
        author: AuthorSummary(id: ProfileID("prof-1"), handle: "ava", displayName: "Ava", avatarURL: nil)
    )
}

struct FeedDisplayModelBuilderTests {
    private let builder = FeedDisplayModelBuilder(cellWidth: 390)
    private let now = Date(timeIntervalSince1970: 3600)

    @Test func longerCaptionsProduceTallerCells() {
        let short = builder.build([entry(caption: "Hi.")], relativeTo: now)[0]
        let long = builder.build([entry(caption: String(repeating: "A reasonably long sentence about nothing. ", count: 8))], relativeTo: now)[0]
        #expect(long.height > short.height)
        #expect(long.captionHeight > short.captionHeight)
    }

    @Test func emptyCaptionContributesZeroHeight() {
        let model = builder.build([entry(caption: "   ")], relativeTo: now)[0]
        #expect(model.caption == nil)
        #expect(model.captionHeight == 0)
    }

    @Test func mediaHeightFollowsClampedAspectRatio() {
        let contentWidth: CGFloat = 390 - 32
        let square = builder.build([entry(caption: "", media: (1080, 1080))], relativeTo: now)[0]
        #expect(square.mediaHeight == contentWidth.rounded(.up))

        // 9:16 portrait must clamp to the 4:5 cap, not stretch endlessly.
        let tall = builder.build([entry(caption: "", media: (900, 1600))], relativeTo: now)[0]
        #expect(tall.mediaHeight == (contentWidth / 0.8).rounded(.up))
    }

    @Test func heightIsSumOfPartsAndDeterministic() {
        let model = builder.build([entry(caption: "One line.", media: (1600, 900))], relativeTo: now)[0]
        let again = builder.build([entry(caption: "One line.", media: (1600, 900))], relativeTo: now)[0]
        #expect(model.height == again.height)
        #expect(model.height > model.captionHeight + model.mediaHeight)
    }

    @Test func relativeTimestampsAreCompact() {
        let model = builder.build(
            [entry(caption: "x", publishedAt: Date(timeIntervalSince1970: 3600 - 180))],
            relativeTo: now
        )[0]
        #expect(model.metaText == "@ava · 3m")
    }
}
