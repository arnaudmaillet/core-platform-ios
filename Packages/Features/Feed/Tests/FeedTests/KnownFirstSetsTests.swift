import CoreModels
import EntityStore
import FeedInterface
import Foundation
import MediaCore
import PostGrid
import Synchronization
import Testing
import UIKit
@testable import Feed

/// Posts the app already holds are drawn before the network answers (#1863):
/// a post set's cards, a cluster's feed.
@MainActor
struct KnownFirstSetsTests {
    private static func post(_ id: String) -> GalleryPost {
        GalleryPost(id: PostID(id), kind: .photo, isRepost: false, thumbnailURL: nil, caption: id, publishedAtMS: 0, reactionCount: 4)
    }

    private func surface(
        _ style: PostSetSurfaceStyle, held: Set<String>, hydrate: @escaping ([PostID]) async -> [GalleryPost]
    ) -> PostSetSurfaceViewController {
        PostSetSurfaceViewController(
            style: style,
            imagePipeline: ImagePipeline(fetcher: PlaceholderImageFetcher()),
            videoPlayback: nil,
            held: { id in held.contains(id.rawValue) ? Self.post(id.rawValue) : nil },
            hydrate: hydrate
        )
    }

    // MARK: - Post sets

    /// ⚠️ A HASHTAG OPENED AFTER ITS POSTS WERE SEEN SHOWS THEM AT ONCE: the
    /// lead row is drawn before the hydration, with no bones.
    @Test func aRowOfHeldPostsIsDrawnAtOnce() {
        let page = surface(.discover, held: ["a", "b"]) { _ in
            try? await Task.sleep(for: .seconds(30))
            return []
        }
        page.showLeadRow(.posts([PostID("a"), PostID("b")]))
        #expect(page.debugLeadRowIDs == [PostID("a"), PostID("b")], "the row waited for the network")
        #expect(page.debugShelf?.isLoading == false, "a held row wears its bones")
    }

    /// The list draws what is held now, and the hydration completes it.
    @Test func aListDrawsWhatIsHeldThenTheRest() async {
        let page = surface(.cards, held: ["a", "c"]) { ids in ids.map { Self.post($0.rawValue) } }
        page.show(.posts([PostID("a"), PostID("b"), PostID("c")]))
        #expect(page.debugShownPostIDs == [PostID("a"), PostID("c")], "the held posts waited")
        for _ in 0..<400 where page.debugShownPostIDs.count < 3 { try? await Task.sleep(for: .milliseconds(5)) }
        #expect(page.debugShownPostIDs == [PostID("a"), PostID("b"), PostID("c")])
    }

    // MARK: - The store's counts

    /// A like count the store does not know is the card's unknown state, never
    /// a zero; a known one rides along until the counter read.
    @Test func anUnknownCountStaysUnknown() {
        let store = EntityStore()
        let author = AuthorSummary(id: ProfileID("ava"), handle: "ava", displayName: "Ava", avatarURL: nil)
        let post = Post(id: PostID("p1"), authorID: author.id, caption: "", attachments: [], publishedAt: Date())
        store.upsert(author)
        store.replacePost(post)
        let feed = FeedFeatureBuilder(
            repository: EmptyFeed(), imagePipeline: ImagePipeline(fetcher: PlaceholderImageFetcher()), entities: store
        )
        #expect(feed.heldGalleryPost(PostID("p1")) != nil)
        #expect(feed.heldGalleryPost(PostID("p1"))?.reactionCount == nil, "an unknown count drew a zero")
        store.setLikeCount(9, for: PostID("p1"))
        #expect(feed.heldGalleryPost(PostID("p1"))?.reactionCount == 9)
        // A post deleted in this session is held by no one.
        store.deletePost(PostID("p1"))
        #expect(feed.heldGalleryPost(PostID("p1")) == nil)
    }

    // MARK: - Clusters

    /// ⚠️ ONE COLD MEMBER NO LONGER HOLDS THE CLUSTER BACK: the feed opens on
    /// the held members, the opening post first.
    @Test func aClusterWithAColdMemberOpensOnWhatIsHeld() {
        let held = Self.entry("rep")
        let builder = FeedFeatureBuilder(
            repository: MirrorFeed(held: [held]), imagePipeline: ImagePipeline(fetcher: PlaceholderImageFetcher())
        )
        let feed = builder.makeSnapFeedViewController(postIDs: [PostID("rep"), PostID("cold")], ownsInteractiveDismissal: true)
        #expect((feed as? SnapFeedViewController)?.orderedIDs == [PostID("rep")], "the held representative waited")
        // The opening post unknown: its loading page, as before — no seed.
        let cold = builder.makeSnapFeedViewController(postIDs: [PostID("cold"), PostID("rep")], ownsInteractiveDismissal: true)
        #expect((cold as? SnapFeedViewController)?.orderedIDs.isEmpty == true)
    }

    /// Five cold members load together, not one after another.
    @Test func coldMembersLoadInParallel() async {
        let counter = ConcurrencyCounter()
        let ids = (1...5).map { PostID("m\($0)") }
        let entries = await FeedFeatureBuilder.loadConcurrently(ids, from: CountingFeed(counter: counter))
        #expect(entries.map(\.post.id) == ids, "the cluster's order was lost")
        #expect(counter.peak > 1, "the members loaded one by one")
    }

    // MARK: - Fixtures

    nonisolated static func entry(_ id: String) -> FeedEntry {
        let author = AuthorSummary(id: ProfileID("ava"), handle: "ava", displayName: "Ava", avatarURL: nil)
        let post = Post(
            id: PostID(id), authorID: author.id, caption: id,
            attachments: [MediaAttachment(
                url: URL(string: "https://example.test/\(id).jpg"), thumbnailURL: nil, mimeType: "image/jpeg",
                pixelWidth: 3, pixelHeight: 4
            )],
            publishedAt: Date()
        )
        return FeedEntry(post: post, author: author, likeCount: 1)
    }
}

private struct EmptyFeed: FeedProviding {
    func cachedFirstPage() async -> [FeedEntry]? { nil }
    func loadFirstPage() async throws -> FeedPage { FeedPage(entries: [], nextPageToken: nil, isCold: false) }
    func loadPage(afterToken token: String) async throws -> FeedPage { FeedPage(entries: [], nextPageToken: nil, isCold: false) }
    func loadPost(_ id: PostID) async throws -> FeedEntry { throw FeedError.transport(message: "offline") }
}

private struct MirrorFeed: FeedProviding {
    let held: [FeedEntry]
    func cachedFirstPage() async -> [FeedEntry]? { nil }
    func loadFirstPage() async throws -> FeedPage {
        try await Task.sleep(for: .seconds(30))
        return FeedPage(entries: [], nextPageToken: nil, isCold: false)
    }
    func loadPage(afterToken token: String) async throws -> FeedPage { FeedPage(entries: [], nextPageToken: nil, isCold: false) }
    func loadPost(_ id: PostID) async throws -> FeedEntry {
        try await Task.sleep(for: .seconds(30))
        throw FeedError.transport(message: "slow")
    }
    nonisolated func peekPost(_ id: PostID) -> FeedEntry? { held.first { $0.post.id == id } }
}

/// The most loads in flight at once.
private final class ConcurrencyCounter: Sendable {
    private let state = Mutex<(now: Int, peak: Int)>((0, 0))
    func enter() { state.withLock { $0.now += 1; $0.peak = max($0.peak, $0.now) } }
    func leave() { state.withLock { $0.now -= 1 } }
    var peak: Int { state.withLock { $0.peak } }
}

private struct CountingFeed: FeedProviding {
    let counter: ConcurrencyCounter
    func cachedFirstPage() async -> [FeedEntry]? { nil }
    func loadFirstPage() async throws -> FeedPage { FeedPage(entries: [], nextPageToken: nil, isCold: false) }
    func loadPage(afterToken token: String) async throws -> FeedPage { FeedPage(entries: [], nextPageToken: nil, isCold: false) }
    func loadPost(_ id: PostID) async throws -> FeedEntry {
        counter.enter()
        try? await Task.sleep(for: .milliseconds(50))
        counter.leave()
        return KnownFirstSetsTests.entry(id.rawValue)
    }
}
