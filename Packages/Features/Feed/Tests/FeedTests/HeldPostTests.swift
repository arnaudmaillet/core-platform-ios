import CoreModels
import EntityStore
import Foundation
import MediaCore
import Testing
@testable import Feed

/// A post the app holds opens at once (#1862): the feed's mirror first, then
/// the app's store — whose device backing holds posts the mirror never saw.
@MainActor
struct HeldPostTests {
    private struct EmptyProvider: FeedProviding {
        func cachedFirstPage() async -> [FeedEntry]? { nil }
        func loadFirstPage() async throws -> FeedPage { FeedPage(entries: [], nextPageToken: nil, isCold: false) }
        func loadPage(afterToken token: String) async throws -> FeedPage { FeedPage(entries: [], nextPageToken: nil, isCold: false) }
        func loadPost(_ id: PostID) async throws -> FeedEntry { throw FeedError.transport(message: "offline") }
    }

    private struct MirrorProvider: FeedProviding {
        let held: FeedEntry
        func cachedFirstPage() async -> [FeedEntry]? { nil }
        func loadFirstPage() async throws -> FeedPage { FeedPage(entries: [], nextPageToken: nil, isCold: false) }
        func loadPage(afterToken token: String) async throws -> FeedPage { FeedPage(entries: [], nextPageToken: nil, isCold: false) }
        func loadPost(_ id: PostID) async throws -> FeedEntry { throw FeedError.transport(message: "offline") }
        nonisolated func peekPost(_ id: PostID) -> FeedEntry? { id == held.post.id ? held : nil }
    }

    private static func entry(_ id: String, likes: Int64 = 7) -> FeedEntry {
        let author = AuthorSummary(id: ProfileID("ava"), handle: "ava", displayName: "Ava", avatarURL: nil)
        let post = Post(
            id: PostID(id), authorID: author.id, caption: "c",
            attachments: [MediaAttachment(
                url: URL(string: "https://example.test/\(id).jpg"), thumbnailURL: nil, mimeType: "image/jpeg",
                pixelWidth: 3, pixelHeight: 4
            )],
            publishedAt: Date()
        )
        return FeedEntry(post: post, author: author, likeCount: likes)
    }

    private func builder(_ repository: any FeedProviding, entities: EntityStore) -> FeedFeatureBuilder {
        FeedFeatureBuilder(
            repository: repository, imagePipeline: ImagePipeline(fetcher: PlaceholderImageFetcher()), entities: entities
        )
    }

    @Test func theMirrorAnswersFirst() {
        let held = Self.entry("p1")
        let feed = builder(MirrorProvider(held: held), entities: EntityStore())
        #expect(feed.heldGalleryPost(PostID("p1"))?.id == PostID("p1"))
    }

    /// ⚠️ A MIRROR MISS ASKS THE STORE before anything waits: a push or a
    /// notification to a post the device holds opens on it.
    @Test func theStoreAnswersWhatTheMirrorDoesNot() {
        let store = EntityStore()
        store.upsert([Self.entry("p2", likes: 12)])
        let feed = builder(EmptyProvider(), entities: store)
        #expect(feed.heldGalleryPost(PostID("p2"))?.id == PostID("p2"))
        #expect(FeedFeatureBuilder.entry(PostID("p2"), in: store)?.likeCount == 12)
        #expect(feed.heldGalleryPost(PostID("nowhere")) == nil, "a post nobody holds answered")
    }

    /// The store needs the author too: counts alone are no post to open.
    @Test func countsAloneAreNoPost() {
        let store = EntityStore()
        store.mergeCounts([PostID("p3"): PostCounts(likes: 3)])
        #expect(FeedFeatureBuilder.entry(PostID("p3"), in: store) == nil)
    }
}
