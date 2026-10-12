import CoreModels
import EntityStore
import Foundation
import PostGrid
import Synchronization
import Testing
@testable import Feed

/// A post deleted anywhere — the author's profile — leaves For You's grid
/// and rows, and nothing the session loads later brings it back (#896).
@MainActor
struct ForYouDeletedPostTests {
    private func post(_ id: String, by author: String) -> GalleryPost {
        GalleryPost(
            id: PostID(id), kind: .photo, isRepost: false, thumbnailURL: nil,
            caption: "caption \(id)", publishedAtMS: 10, authorID: ProfileID(author)
        )
    }

    private func loaded(
        _ provider: DeletedPostStubProvider, entities: EntityStore
    ) async -> (ForYouViewModel, () -> Int) {
        let model = ForYouViewModel(repository: provider, entities: entities)
        var resets = 0
        model.onCorpusReset = { resets += 1 }
        model.viewDidLoad()
        for _ in 0..<40 where model.followingPosts.isEmpty {
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(5))
        }
        return (model, { resets })
    }

    private func settle(until condition: () -> Bool) async -> Bool {
        for _ in 0..<200 {
            if condition() { return true }
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(5))
        }
        return condition()
    }

    @Test func aPostDeletedElsewhereLeavesDiscoverAndTheRows() async {
        let entities = EntityStore()
        let provider = DeletedPostStubProvider(
            following: [post("a1", by: "sofia"), post("b1", by: "marcus")],
            discovery: [post("a1", by: "sofia"), post("d1", by: "lena")]
        )
        let (model, resets) = await loaded(provider, entities: entities)
        #expect(Set(model.followingPosts.map(\.id.rawValue)) == ["a1", "b1"])
        let before = resets()

        // Deleted from the author's profile.
        entities.deletePost(PostID("a1"))

        #expect(model.followingPosts.map(\.id.rawValue) == ["b1"])
        #expect(model.discoverPosts.map(\.id.rawValue) == ["d1"])
        #expect(model.post(for: PostID("a1")) == nil)
        #expect(resets() == before + 1, "a removal re-derives the pages")
    }

    @Test func aRefreshAndALaterPageServingItAgainKeepItOut() async {
        let entities = EntityStore()
        let provider = DeletedPostStubProvider(
            following: [post("a1", by: "sofia"), post("b1", by: "marcus")],
            discovery: [post("d1", by: "lena")],
            nextFollowing: [post("a1", by: "sofia"), post("c1", by: "marcus")],
            nextDiscovery: [post("a1", by: "sofia"), post("d2", by: "lena")]
        )
        let (model, _) = await loaded(provider, entities: entities)
        entities.deletePost(PostID("a1"))

        // A page fetched before the delete reached the server's index.
        model.loadNextPageIfNeeded(.following)
        model.loadNextPageIfNeeded(.discover)
        #expect(await settle { Set(model.followingPosts.map(\.id.rawValue)) == ["b1", "c1"] })
        #expect(await settle { model.discoverPosts.map(\.id.rawValue) == ["d1", "d2"] })

        // And a refresh.
        model.refresh()
        #expect(await settle { provider.firstPageCalls == 2 })
        #expect(await settle { !model.followingPosts.isEmpty })
        #expect(!model.followingPosts.contains { $0.id == PostID("a1") })
        #expect(!model.discoverPosts.contains { $0.id == PostID("a1") })
    }

    /// The device's corpus at a cold start (#893) carries it too.
    @Test func theRestoredCorpusLeavesItOut() async {
        let entities = EntityStore()
        entities.deletePost(PostID("a1"))
        let provider = DeletedPostStubProvider(
            following: [post("b1", by: "marcus")],
            discovery: [post("d1", by: "lena")],
            cached: ForYouCachedPages(
                discovery: ForYouPage(posts: [post("a1", by: "sofia"), post("d1", by: "lena")], nextPageToken: nil),
                following: ForYouPage(posts: [post("a1", by: "sofia"), post("b1", by: "marcus")], nextPageToken: nil),
                relations: [:]
            ),
            holdsFirstPage: true
        )
        let model = ForYouViewModel(repository: provider, entities: entities)

        model.viewDidLoad()

        #expect(model.followingPosts.map(\.id.rawValue) == ["b1"], "the first frame is the device's, without it")
        #expect(model.discoverPosts.map(\.id.rawValue) == ["d1"])
    }

    /// Another post's change (a like, a tick) moves nothing on this screen.
    @Test func aCountChangeIsNotADelete() async {
        let entities = EntityStore()
        let provider = DeletedPostStubProvider(following: [post("a1", by: "sofia")], discovery: [])
        let (model, resets) = await loaded(provider, entities: entities)
        let before = resets()

        entities.setLikeCount(5, for: PostID("a1"))

        #expect(model.followingPosts.map(\.id.rawValue) == ["a1"])
        #expect(resets() == before)
    }
}

private final class DeletedPostStubProvider: ForYouProviding, @unchecked Sendable {
    private let following: [GalleryPost]
    private let discovery: [GalleryPost]
    private let nextFollowing: [GalleryPost]
    private let nextDiscovery: [GalleryPost]
    private let cached: ForYouCachedPages?
    /// The first network page never answers: the screen stays on the
    /// device's corpus.
    private let holdsFirstPage: Bool
    private let calls = Mutex(0)

    init(
        following: [GalleryPost], discovery: [GalleryPost],
        nextFollowing: [GalleryPost] = [], nextDiscovery: [GalleryPost] = [],
        cached: ForYouCachedPages? = nil, holdsFirstPage: Bool = false
    ) {
        self.following = following
        self.discovery = discovery
        self.nextFollowing = nextFollowing
        self.nextDiscovery = nextDiscovery
        self.cached = cached
        self.holdsFirstPage = holdsFirstPage
    }

    var firstPageCalls: Int { calls.withLock { $0 } }

    func firstPage() async throws -> ForYouPage {
        calls.withLock { $0 += 1 }
        if holdsFirstPage { try await Task.sleep(for: .seconds(60)) }
        return ForYouPage(posts: following, nextPageToken: nextFollowing.isEmpty ? nil : "f2")
    }

    func page(after token: String) async throws -> ForYouPage {
        ForYouPage(posts: nextFollowing, nextPageToken: nil)
    }

    func discoveryFirstPage() async throws -> ForYouPage? {
        if holdsFirstPage { try await Task.sleep(for: .seconds(60)) }
        return ForYouPage(posts: discovery, nextPageToken: nextDiscovery.isEmpty ? nil : "d2")
    }

    func discoveryPage(after token: String) async throws -> ForYouPage? {
        ForYouPage(posts: nextDiscovery, nextPageToken: nil)
    }

    func cachedPages() -> ForYouCachedPages? { cached }
}
