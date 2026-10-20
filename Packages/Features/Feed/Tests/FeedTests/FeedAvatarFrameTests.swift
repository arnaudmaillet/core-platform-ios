import CoreContracts
import CoreModels
import Foundation
import Testing
@testable import Feed

/// The author's avatar frame (#943) rides from the profile read to the snap
/// pill and the comment rows, and through both device stores.
struct FeedAvatarFrameTests {
    private static let author = AuthorSummary(
        id: ProfileID("prof-0"), handle: "ava", displayName: "Ava", avatarURL: nil, avatarFrameID: "frame.neon"
    )

    @Test func aFeedModelCarriesItsAuthorsFrame() {
        let entry = FeedEntry(
            post: Post(
                id: PostID("p"), authorID: Self.author.id, caption: "", attachments: [],
                publishedAt: Date(timeIntervalSince1970: 0)
            ),
            author: Self.author
        )
        let model = FeedDisplayModelBuilder().build(entry, now: Date(timeIntervalSince1970: 0))
        #expect(model.avatarFrameID == "frame.neon")
    }

    /// An author summary stored before the frame decodes with none.
    @Test func anAuthorStoredBeforeTheFrameDecodesWithNone() throws {
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(Self.author)) as? [String: Any])
        json.removeValue(forKey: "avatarFrameID")
        let decoded = try JSONDecoder().decode(AuthorSummary.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(decoded.avatarFrameID == nil)
        #expect(decoded.handle == "ava")
    }

    /// The local cache's summary view keeps it; an empty field is none.
    @Test func theCachedSummaryKeepsTheFrame() {
        let view = FeedLocalCache.summaryView(from: Self.author)
        #expect(view.avatarFrameID == "frame.neon")
        let bare = FeedLocalCache.summaryView(from: AuthorSummary(
            id: ProfileID("prof-1"), handle: "kenji", displayName: "Kenji", avatarURL: nil
        ))
        #expect(bare.avatarFrameID.isEmpty)
    }

    @Test func aCommentRowCarriesItsAuthorsFrame() {
        let entry = CommentEntry(
            id: "c1", authorID: Self.author.id, authorName: "Ava", authorHandle: "ava",
            authorAvatarFrameID: "frame.gold", body: "Nice", createdAt: Date(timeIntervalSince1970: 0)
        )
        #expect(CommentDisplayModel(entry: entry).avatarFrameID == "frame.gold")
        #expect(entry.released().authorAvatarFrameID == "frame.gold", "approving keeps the frame")
    }

    /// The comments' disk records keep it, and a record written before it
    /// decodes with none.
    @Test func aStoredCommentKeepsItsAuthorsFrame() throws {
        let entry = CommentEntry(
            id: "c1", authorID: Self.author.id, authorName: "Ava", authorHandle: "ava",
            authorAvatarFrameID: "frame.aurora", body: "Nice", createdAt: Date(timeIntervalSince1970: 0)
        )
        let record = CommentsDiskTier.Record(entry)
        let data = try JSONEncoder().encode(record)
        #expect(try JSONDecoder().decode(CommentsDiskTier.Record.self, from: data).entry.authorAvatarFrameID == "frame.aurora")
        var json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        json.removeValue(forKey: "authorAvatarFrameID")
        let old = try JSONDecoder().decode(CommentsDiskTier.Record.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(old.entry.authorAvatarFrameID == nil)
    }
}
