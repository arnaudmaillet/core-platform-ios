import CoreModels
import CoreStorage
import EntityStore
import FeedInterface
import Foundation
import MediaCore
import PostGrid
import Testing
import UIKit
@testable import Feed

/// The surfaces #896 B left on their loaded counts: search results (and the
/// gallery they push), and the Following cards' flights and stand-ins. Each
/// draws the post's live count from the app's `EntityStore`.
@MainActor
struct LiveCountSurfacesTests {
    private static func wallet() -> WalletStore {
        let name = "live-count-surfaces-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return WalletStore(defaults: defaults)
    }

    private static func post(_ id: String, likes: Int64?) -> GalleryPost {
        GalleryPost(
            id: PostID(id), kind: .photo, isRepost: false, thumbnailURL: nil,
            caption: id, publishedAtMS: 0, authorID: ProfileID("a-\(id)"),
            authorName: "Nina Varga", authorHandle: "nina.varga", reactionCount: likes
        )
    }

    private func settleUntil(_ condition: () -> Bool) async {
        for _ in 0..<2_000 {
            await Task.yield()
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    // MARK: - Search results

    /// A search result, liked in the feed it opened (the store moved), opens
    /// again with the live count on its flight: the card leaves the tile with
    /// the number the tile draws.
    @Test func aSearchResultOpensWithItsLiveCount() async throws {
        let entities = EntityStore()
        let posts = (1...4).map { Self.post("p\($0)", likes: 40) }
        let byID = Dictionary(uniqueKeysWithValues: posts.map { ($0.id, $0) })
        let surface = PostSetSurfaceViewController(
            style: .cards,
            imagePipeline: ImagePipeline(fetcher: PlaceholderImageFetcher()),
            videoPlayback: nil,
            hydrate: { ids in ids.compactMap { byID[$0] } }
        )
        surface.staking = PostCardStaking(wallet: Self.wallet(), entities: entities)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        let navigation = UINavigationController(rootViewController: surface)
        window.rootViewController = navigation
        window.makeKeyAndVisible()
        window.layoutIfNeeded()
        surface.show(.posts(posts.map(\.id)))
        // The bound rows told the store the count they loaded.
        await settleUntil {
            window.layoutIfNeeded()
            return entities.post(PostID("p1"))?.likeCount == 40
        }
        #expect(entities.post(PostID("p1"))?.likeCount == 40, "the result's card is bound")

        // Liked in the vertical feed opened from it.
        entities.addLikes(1, to: PostID("p1"))

        var opened: SnapFeedHeroOrigin?
        surface.openPost = { _, origin, _ in opened = origin }
        await settleUntil {
            window.layoutIfNeeded()
            return surface.debugOpenTile(at: 0) && opened != nil
        }
        let origin = try #require(opened)
        #expect(origin.post.reactionCount == 41)
        #expect(origin.stream.first?.reactionCount == 41)
        #expect(origin.stream.dropFirst().allSatisfy { $0.reactionCount == 40 })
    }

    // MARK: - Following cards

    /// A Following card's flight, and the stand-in its close lands as, draw
    /// the live count — a like made in the feed it opened included.
    @Test func aFollowingCardsFlightAndStandInsDrawTheLiveCount() {
        let entities = EntityStore()
        let lead = ForYouLeadFixture(pipeline: ImagePipeline(fetcher: PlaceholderImageFetcher()), videoPlayback: nil)
        lead.shelf.staking = PostCardStaking(wallet: Self.wallet(), entities: entities)
        let page = ForYouGridPage(imagePipeline: ImagePipeline(fetcher: PlaceholderImageFetcher()), style: .discover, videoPlayback: nil)
        let card = Self.post("c1", likes: 123)
        entities.mergeCounts([card.id: PostCounts(likes: 123)])

        // Liked in the feed.
        entities.addLikes(1, to: card.id)

        #expect(lead.shelf.livePost(card).reactionCount == 124)
        let origin = PostShelfOrigins.card(card, stream: [card], shelf: lead.shelf, page: page, host: lead.stack)
        #expect(origin.post.reactionCount == 124)
        #expect(origin.stream.map(\.reactionCount) == [124])
    }

    /// A count the author hides stays hidden on every copy.
    @Test func aHiddenCountStaysHiddenOnTheFlight() {
        let entities = EntityStore()
        let lead = ForYouLeadFixture(pipeline: ImagePipeline(fetcher: PlaceholderImageFetcher()), videoPlayback: nil)
        lead.shelf.staking = PostCardStaking(wallet: Self.wallet(), entities: entities)
        var card = Self.post("c1", likes: nil)
        card.likeCountsHidden = true
        entities.setLikeCount(99, for: card.id)
        #expect(lead.shelf.livePost(card).reactionCount == nil)
    }
}
