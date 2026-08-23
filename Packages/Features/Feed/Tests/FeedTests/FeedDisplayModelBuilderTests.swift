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

/// A collection's pages carry their own type all the way to the page's model.
///
/// ⚠️ `attachments` is repeated and every element has its own MIME. This builder
/// mapped a thumbnail and an aspect for the tail and dropped the rest, so a clip
/// on page two reached the post page as a photograph — no badge, nothing to
/// play, and no error anywhere: a still is a perfectly valid thing for a page to
/// be. Only a mixed post shows it.
struct MixedCollectionModelTests {
    private func attachment(mime: String, url: String) -> MediaAttachment {
        MediaAttachment(
            url: URL(string: url), thumbnailURL: URL(string: "https://example.com/poster.jpg"),
            mimeType: mime, pixelWidth: 1600, pixelHeight: 900
        )
    }

    private func model(_ attachments: [MediaAttachment]) -> FeedItemDisplayModel {
        FeedDisplayModelBuilder().build(
            FeedEntry(
                post: Post(
                    id: PostID("p"), authorID: ProfileID("prof-1"), caption: "",
                    attachments: attachments, publishedAt: Date(timeIntervalSince1970: 0)
                ),
                author: AuthorSummary(
                    id: ProfileID("prof-1"), handle: "ava", displayName: "Ava", avatarURL: nil
                )
            ),
            now: Date(timeIntervalSince1970: 0)
        )
    }

    @Test func aClipAfterTheHeadKeepsItsStream() {
        let built = model([
            attachment(mime: "image/jpeg", url: "https://example.com/one.jpg"),
            attachment(mime: "video/mp4", url: "https://example.com/two.mp4"),
            attachment(mime: "image/jpeg", url: "https://example.com/three.jpg")
        ])
        let pages = built.mediaPages

        #expect(pages.count == 3)
        #expect(pages[0].videoURL == nil)
        #expect(pages[1].videoURL == URL(string: "https://example.com/two.mp4"))
        #expect(pages[2].videoURL == nil)
        // The POST is still a photo post — its head decides that — which is
        // exactly why nothing downstream may ask the post whether it plays.
        #expect(built.mediaKind == .image)
    }

    /// ⚠️ Routed through `MediaKind`, not a `video/` prefix.
    ///
    /// An HLS manifest declares `application/vnd.apple.mpegurl`, which a prefix
    /// test reads as a still — and HLS is what the backend serves where it has
    /// a ladder, so the prefix version would have failed on exactly the streams
    /// that matter most.
    @Test func anHLSPageIsAlsoAStream() {
        let pages = model([
            attachment(mime: "image/jpeg", url: "https://example.com/one.jpg"),
            attachment(mime: "application/vnd.apple.mpegurl", url: "https://example.com/two.m3u8")
        ]).mediaPages

        #expect(pages[1].videoURL == URL(string: "https://example.com/two.m3u8"))
    }
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
