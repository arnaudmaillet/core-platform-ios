import CacheKit
import CoreContracts
import CoreModels
import Foundation
import LocalStore
import MediaCore
import PostGrid
import Synchronization
import Testing
import UIKit
@testable import Feed

/// Pages fetched ahead of the viewer (#970) are stored `speculative` on the
/// device and promoted to `recent` when one of their posts is first shown, so
/// the speculative cap and the waste ratio cover data too.
final class FeedPrefetchedPagesTests {
    private final class Folder: Sendable {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "FeedPrefetchedPagesTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        deinit { try? FileManager.default.removeItem(at: url) }
    }

    /// Answers fixed pages.
    private final class FixedFeed: FeedProviding, @unchecked Sendable {
        let first: FeedPage
        let next: [String: FeedPage]

        init(first: FeedPage, next: [String: FeedPage]) {
            self.first = first
            self.next = next
        }

        func cachedFirstPage() async -> [FeedEntry]? { nil }
        func loadFirstPage() async throws -> FeedPage { first }
        func loadPage(afterToken token: String) async throws -> FeedPage {
            next[token] ?? FeedPage(entries: [], nextPageToken: nil, isCold: false)
        }
        func loadPost(_ id: PostID) async throws -> FeedEntry { FeedPrefetchedPagesTests.entry(id.rawValue) }
    }

    private let folder = Folder()
    private let viewer: LocalStoreViewer = .member(account: "acct-1", profile: "prof-1")

    static func entry(_ id: String) -> FeedEntry {
        FeedEntry(
            post: Post(
                id: PostID(id), authorID: ProfileID("author-\(id)"), caption: "caption \(id)",
                attachments: [MediaAttachment(
                    url: URL(string: "https://cdn.example/\(id).jpg"), thumbnailURL: nil,
                    mimeType: "image/jpeg", pixelWidth: 1080, pixelHeight: 1350
                )],
                publishedAt: Date(timeIntervalSince1970: 1_760_000_000)
            ),
            author: AuthorSummary(id: ProfileID("author-\(id)"), handle: "h-\(id)", displayName: "Name \(id)", avatarURL: nil),
            likeCount: 0
        )
    }

    private func page(_ ids: [String], next: String?) -> FeedPage {
        FeedPage(entries: ids.map(Self.entry), nextPageToken: next, isCold: false)
    }

    private func makeCache() throws -> FeedLocalCache {
        let current = viewer
        return FeedLocalCache(store: try LocalStore(directory: folder.url, viewer: { current }))
    }

    private func speculativeBytes(_ cache: FeedLocalCache) -> Int {
        cache.store.waitForPendingWrites()
        return cache.store.usage.bytesByTier[.speculative, default: 0]
    }

    /// ⚠️ For You's next pages are fetched ahead (`LookaheadPaging`): stored
    /// speculative, Discover's and the following timeline's alike, and each
    /// promoted, counted as used, when one of its posts is shown.
    @Test func forYousNextPagesAreSpeculativeUntilOneOfTheirPostsIsShown() async throws {
        let cache = try makeCache()
        let discover = FixedFeed(first: page(["d1", "d2"], next: "dc1"), next: ["dc1": page(["d3", "d4"], next: "dc2")])
        let following = FixedFeed(first: page(["f1"], next: "fc1"), next: ["fc1": page(["f2", "f3"], next: nil)])
        let repository = ForYouRepository(feed: following, discovery: discover, localCache: cache)
        _ = try await repository.discoveryFirstPage()
        _ = try await repository.firstPage()
        #expect(speculativeBytes(cache) == 0, "a first page is retained")

        _ = try await repository.discoveryPage(after: "dc1")
        let discoverAhead = speculativeBytes(cache)
        #expect(discoverAhead > 0, "Discover's next page was not stored as speculative")
        _ = try await repository.page(after: "fc1")
        let both = speculativeBytes(cache)
        #expect(both > discoverAhead, "the following timeline's next page was not stored as speculative")
        #expect(cache.store.statistics.speculative.stored == 2)

        repository.didShow(PostID("d4"))
        let left = speculativeBytes(cache)
        #expect(left > 0 && left < both, "showing d4 promoted Discover's page, and only it")
        repository.didShow(PostID("f2"))
        #expect(speculativeBytes(cache) == 0)
        let fates = cache.store.statistics.speculative
        #expect(fates.used == 2)
        #expect(fates.wasteRatio == 0)

        // Shown again: nothing more to promote.
        repository.didShow(PostID("f3"))
        cache.store.waitForPendingWrites()
        #expect(cache.store.statistics.speculative.used == 2)
    }

    /// The vertical Following feed's next page (5 posts left) is fetched
    /// ahead too: `FeedRepository` stores it speculative.
    @Test func aPageFetchedAheadByTheVerticalFeedIsSpeculative() throws {
        let cache = try makeCache()
        cache.storeFirstPage([Self.entry("p1")], nextCursor: "c1", in: .following, as: viewer)
        cache.storeNextPage([Self.entry("p2")], nextCursor: nil, after: "c1", in: .following, as: viewer, tier: .speculative)
        #expect(speculativeBytes(cache) > 0)
        cache.didShow(PostID("p2"))
        #expect(speculativeBytes(cache) == 0)
    }

    /// A refresh replaces the list: the prefetched page left unshown is
    /// discarded, and a post of it shown later promotes nothing.
    @Test func aRefreshForgetsThePagesFetchedAheadOfTheOldFirstPage() throws {
        let cache = try makeCache()
        cache.storeFirstPage([Self.entry("p1")], nextCursor: "c1", in: .forYouDiscover, as: viewer)
        cache.storeNextPage([Self.entry("p2")], nextCursor: nil, after: "c1", in: .forYouDiscover, as: viewer, tier: .speculative)
        cache.storeFirstPage([Self.entry("n1")], nextCursor: nil, in: .forYouDiscover, as: viewer)
        cache.didShow(PostID("p2"))
        cache.store.waitForPendingWrites()
        let fates = cache.store.statistics.speculative
        #expect(fates.discarded == 1)
        #expect(fates.used == 0)
    }
}

/// The grid page says which post it is about to display: For You's hook for
/// promoting a page fetched ahead (#970).
@MainActor
struct ForYouGridPageDisplayTests {
    private struct SilentFetcher: ImageFetching {
        func fetchImageData(for url: URL) async throws -> Data { Data() }
    }

    @Test func aCellAboutToDisplayNamesItsPost() {
        let page = ForYouGridPage(imagePipeline: ImagePipeline(fetcher: SilentFetcher()), style: .grid)
        page.frame = CGRect(x: 0, y: 0, width: 393, height: 1200)
        let posts = (0..<6).map { index in
            GalleryPost(
                id: PostID("p\(index)"), kind: .photo, isRepost: false,
                thumbnailURL: URL(string: "https://example.com/\(index).jpg"), aspectRatio: 1,
                caption: "post \(index)", publishedAtMS: Int64(10_000 - index)
            )
        }
        page.render(.content(posts))
        page.layoutIfNeeded()
        var shown: [PostID] = []
        page.onWillDisplayPost = { shown.append($0) }
        page.collectionView(page.collectionView, willDisplay: UICollectionViewCell(), forItemAt: IndexPath(item: 4, section: 0))
        #expect(shown == [PostID("p4")])
    }
}
