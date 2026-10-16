import CoreContracts
import CoreModels
import CoreNetworking
import CoreNetworkingMocks
import FeedInterface
import Foundation
import MediaCore
import PostGrid
import Testing
import UIKit
@testable import Feed

/// A place's posts past the map's pins, page by page (#643): geo_discovery.v1
/// `ListPlacePosts` over the mock, then the place page that appends them.
@MainActor
struct PlacePostsTests {
    // MARK: - The listing over the mock

    /// Likes read off the post id's number, so the POPULAR order is known.
    nonisolated private static func likes(_ postID: String) -> Int64 {
        Int64(postID.filter(\.isNumber)) ?? 0
    }

    private func repository(countryOf: (@Sendable (Double, Double) -> String?)? = nil) -> (PlacePostsRepository, MockGeoDiscoveryService) {
        let bff = MockBFF()
        let geo = MockGeoDiscoveryService(dataset: MockSocialDataset(), likeCount: Self.likes, countryOf: countryOf)
        geo.register(on: bff)
        let client = ConnectClientFactory.makeUnauthenticated(host: "https://mock.bff.local", httpClient: bff)
        return (PlacePostsRepository(geoClient: GeoDiscovery_V1_GeoDiscoveryServiceClient(client: client)), geo)
    }

    /// Done when: the first request sends a page size, the next one the
    /// previous token, and the walk stops on an empty token — crossing page
    /// boundaries, every post of the place once, most liked first.
    @Test func aCityPagesThroughEveryPostOnceMostLikedFirst() async throws {
        let (repository, geo) = repository()
        let paris = PlaceQuery.city(latitude: 48.8566, longitude: 2.3522)
        let expected = geo.placements()
            .filter { abs($0.latitude - 48.8566) <= 0.15 && abs($0.longitude - 2.3522) <= 0.15 }
            .map(\.postID)
        #expect(expected.count > Int(PlacePostsRepository.pageSize), "precondition: more than one page")

        var pages: [[PostID]] = []
        var token: String?
        repeat {
            let page = try await repository.placePostIDs(paris, after: token)
            pages.append(page.ids)
            token = page.next
        } while token != nil && pages.count < 10

        #expect(pages.first?.count == Int(PlacePostsRepository.pageSize), "the page size went out")
        #expect(pages.count == (expected.count + 49) / 50, "the token moved the walk on, and it stopped")
        let all = pages.flatMap { $0 }.map(\.rawValue)
        #expect(Set(all) == Set(expected))
        #expect(all.count == expected.count, "no post twice")
        let ranked = all.map(Self.likes)
        #expect(ranked == ranked.sorted(by: >))
    }

    /// A country is asked by its code, through the borders the app holds.
    @Test func aCountryListsThePostsItsBordersHold() async throws {
        let (repository, geo) = repository(countryOf: { latitude, _ in latitude > 48.8566 ? "FR" : nil })
        let north = Set(geo.placements().filter { $0.latitude > 48.8566 }.map(\.postID))

        var all: [String] = []
        var token: String?
        repeat {
            let page = try await repository.placePostIDs(.country("fr"), after: token)
            all += page.ids.map(\.rawValue)
            token = page.next
        } while token != nil
        #expect(Set(all) == north)
        #expect(try await repository.placePostIDs(.country("ES"), after: nil).ids.isEmpty)
    }

    // MARK: - The place page

    private func post(_ id: String, kind: GalleryPost.Kind = .photo, reactions: Int64 = 0) -> GalleryPost {
        GalleryPost(
            id: PostID(id), kind: kind, isRepost: false, thumbnailURL: nil,
            caption: "", publishedAtMS: 0, authorName: nil, reactionCount: reactions
        )
    }

    /// The place's pages as a test scripts them, and the tokens asked.
    @MainActor private final class Pages {
        var answers: [String: PlacePostsPage] = [:]
        var pins: [GalleryPost] = []
        private(set) var asked: [String?] = []
        func load(_ token: String?) async throws -> PlacePostsPage {
            asked.append(token)
            guard let answer = answers[token ?? ""] else { throw CancellationError() }
            return answer
        }
    }

    private func makeProfile(_ pages: Pages, opened: ((SnapFeedHeroOrigin) -> Void)? = nil) -> PlaceProfileViewController {
        PlaceProfileViewController(
            postIDs: pages.pins.map(\.id),
            placeName: "Paris • City Cluster",
            imagePipeline: ImagePipeline(fetcher: PlaceholderImageFetcher()),
            videoPlayback: nil,
            loadPosts: { pages.pins },
            loadMore: { try await pages.load($0) },
            openPost: { _, origin, _ in opened?(origin) }
        )
    }

    private func settle(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<6_000 where !condition() {
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    /// Done when: posts shown stay in place as pages land (appended after the
    /// pins in the server's order, a repeat dropped, every kind kept), and
    /// the end loads once and stops.
    @Test func pagesAppendAfterThePinsAndStopAtTheEnd() async {
        let pages = Pages()
        pages.pins = [post("pin-a", reactions: 5), post("pin-b", reactions: 9)]
        pages.answers = [
            "": PlacePostsPage(posts: [post("x1", reactions: 99), post("pin-a"), post("x2", kind: .text)], nextPageToken: "t1"),
            "t1": PlacePostsPage(posts: [post("x3")], nextPageToken: nil),
        ]
        let profile = makeProfile(pages)
        profile.beginLoading()
        #expect(await settle { profile.renderedActivity.count == 2 })
        #expect(profile.renderedActivity.map(\.id.rawValue) == ["pin-b", "pin-a"])

        // A page with more behind it: For You's list holds its last mosaic
        // stretch back until the place is whole (`MosaicChunkPlanner`), so
        // what is shown is the pins, still first.
        profile.loadMorePosts()
        #expect(await settle { pages.asked == [nil] && profile.renderedActivity.count >= 2 })
        #expect(Array(profile.renderedActivity.map(\.id.rawValue).prefix(2)) == ["pin-b", "pin-a"])

        profile.loadMorePosts()
        #expect(await settle { profile.renderedActivity.count == 5 })
        // The most liked post of the pages still comes AFTER the pins.
        #expect(profile.renderedActivity.map(\.id.rawValue) == ["pin-b", "pin-a", "x1", "x2", "x3"])

        profile.loadMorePosts()
        try? await Task.sleep(for: .milliseconds(50))
        #expect(pages.asked == [nil, "t1"], "the first page, then its token, then nothing")
    }

    /// A page with nothing new (POPULAR re-reads its ranking) asks the next
    /// one at once, since no tile reaches the end to ask — a few times, not
    /// forever.
    @Test func emptyPagesAreWalkedAFewTimesNotForever() async {
        let pages = Pages()
        pages.pins = [post("pin-a")]
        for index in 0..<20 {
            pages.answers[index == 0 ? "" : "t\(index)"] = PlacePostsPage(posts: [post("pin-a")], nextPageToken: "t\(index + 1)")
        }
        let profile = makeProfile(pages)
        profile.beginLoading()
        #expect(await settle { profile.renderedActivity.count == 1 })

        profile.loadMorePosts()
        #expect(await settle { pages.asked.count == PlaceProfileViewController.maxEmptyPagesInARow })
        try? await Task.sleep(for: .milliseconds(100))
        #expect(pages.asked.count == PlaceProfileViewController.maxEmptyPagesInARow)
        #expect(profile.renderedActivity.map(\.id.rawValue) == ["pin-a"])
    }

    /// Done when: a refresh doesn't drop loaded pages.
    @Test func aRefreshKeepsThePagesLoaded() async {
        let pages = Pages()
        pages.pins = [post("pin-a", reactions: 5)]
        pages.answers = ["": PlacePostsPage(posts: [post("x1")], nextPageToken: "t1")]
        let profile = makeProfile(pages)
        profile.beginLoading()
        #expect(await settle { profile.renderedActivity.count == 1 })
        profile.loadMorePosts()
        #expect(await settle { profile.renderedActivity.count == 2 })

        // The pins move: a new one, the old one more liked.
        pages.pins = [post("pin-a", reactions: 50), post("pin-c", reactions: 7)]
        profile.refresh()
        #expect(await settle { profile.renderedActivity.count == 3 })
        #expect(profile.renderedActivity.map(\.id.rawValue) == ["pin-a", "pin-c", "x1"])
    }

    /// Done when: a feed opened from a place tile goes on into the place's
    /// next posts — the grid's own past the tapped one, then the next page.
    @Test func aFeedOpenedFromATileContinuesIntoTheNextPage() async throws {
        let pages = Pages()
        pages.pins = [post("pin-a", reactions: 5)]
        pages.answers = ["": PlacePostsPage(posts: [post("x1"), post("x2")], nextPageToken: nil)]
        var origin: SnapFeedHeroOrigin?
        let profile = makeProfile(pages, opened: { origin = $0 })
        profile.view.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        profile.beginLoading()
        #expect(await settle { profile.renderedActivity.count == 1 })

        #expect(await settle { profile.debugOpenTile(at: 0) })
        let continuation = try #require(origin?.continuation)
        let next = await continuation(PostID("pin-a"))
        #expect(next?.map(\.rawValue) == ["x1", "x2"])
        #expect(pages.asked == [nil])
        // The place has nothing past them: the feed ends there.
        #expect(await continuation(PostID("x2")) == nil)
    }

    /// A place with no pages to ask is the map's pins, as before: no
    /// continuation for its feed.
    @Test func withoutPagesTheFeedIsThePins() async throws {
        let pins = [post("pin-a")]
        var origin: SnapFeedHeroOrigin?
        let profile = PlaceProfileViewController(
            postIDs: pins.map(\.id), placeName: "Paris",
            imagePipeline: ImagePipeline(fetcher: PlaceholderImageFetcher()), videoPlayback: nil,
            loadPosts: { pins }, openPost: { _, opened, _ in origin = opened }
        )
        profile.beginLoading()
        #expect(await settle { profile.renderedActivity.count == 1 })
        #expect(await settle { profile.debugOpenTile(at: 0) })
        #expect(origin != nil)
        #expect(origin?.continuation == nil)
    }
}
