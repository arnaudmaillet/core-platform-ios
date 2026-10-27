import CoreStorage
import CoreModels
import FeedInterface
import Foundation
import MediaCore
import PostGrid
import Testing
import UIKit
@testable import Feed

/// Every host of a shelf (#1296, the owner 2026-10-16): its title over
/// skeleton cards until its posts land, then ten cards a row at most — a row
/// ending on the chevron card that runs "View all" only when its list holds
/// more than it shows (#1671, the owner 2026-10-24).
@MainActor
struct ShelfHostsTests {
    private struct SilentFetcher: ImageFetching {
        func fetchImageData(for url: URL) async throws -> Data { Data() }
    }

    private static func posts(_ count: Int, prefix: String) -> [GalleryPost] {
        (0..<count).map { index in
            GalleryPost(
                id: PostID("\(prefix)\(index)"), kind: .photo, isRepost: false,
                thumbnailURL: URL(string: "https://example.test/\(prefix)\(index).jpg"),
                caption: "post \(index)", publishedAtMS: Int64(index),
                authorID: ProfileID("bo"), authorName: "Bo", authorHandle: "bo",
                reactionCount: Int64(100 - index), commentCount: 1
            )
        }
    }

    private static func settle(_ condition: () -> Bool) async {
        for _ in 0..<1_000 {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    /// The landed shelf: ten a row at most, the chevron card last.
    private static func expectLanded(_ shelf: PostShelfSection, of total: Int) {
        #expect(!shelf.isLoading, "the skeleton outlived the posts")
        #expect(shelf.rowCounts.media == min(total, PostShelfSection.rowLimit))
        shelf.layoutIfNeeded()
        #expect(shelf.mediaView.numberOfItems(inSection: 0) == shelf.rowCounts.media + 1,
                "the row does not end on the chevron card")
    }

    /// The landed shelf showing every post it has: no chevron card.
    private static func expectLandedWhole(_ shelf: PostShelfSection, of total: Int) {
        #expect(!shelf.isLoading, "the skeleton outlived the posts")
        #expect(shelf.rowCounts.media == total)
        shelf.layoutIfNeeded()
        #expect(shelf.mediaView.numberOfItems(inSection: 0) == total,
                "a row showing all its posts ends on the chevron card")
    }

    private static func place(
        _ posts: [GalleryPost], popularLastTime: Int? = 10, presence: SectionPresenceStore? = nil
    ) -> PlaceProfileViewController {
        let store = presence ?? SectionPresenceStore(
            defaults: UserDefaults(suiteName: UUID().uuidString)!,
            scope: StorageScope(owner: .member(account: "a", profile: "p"))
        )
        if let popularLastTime { store.remember(popularLastTime, screen: "place.Paris", section: "popular") }
        return PlaceProfileViewController(
            postIDs: posts.map(\.id),
            placeName: "Paris",
            rank: nil,
            imagePipeline: ImagePipeline(fetcher: SilentFetcher()),
            videoPlayback: nil,
            following: nil,
            wallet: nil,
            loadPosts: { posts },
            presence: store,
            openPost: { _, _, _ in }
        )
    }

    /// ⚠️ #1773: the place's Popular wears bones only when it had posts last
    /// time — never seen, or empty then, it fades in; and what lands is
    /// remembered.
    @Test func thePlacesPopularSkeletonFollowsLastKnownPresence() async {
        #expect(Self.place([], popularLastTime: 10).debugShelf.isLoading)
        #expect(!Self.place([], popularLastTime: 0).debugShelf.isLoading, "an empty Popular last time has bones")
        #expect(!Self.place([], popularLastTime: nil).debugShelf.isLoading, "a Popular never seen shimmers")

        let store = SectionPresenceStore(
            defaults: UserDefaults(suiteName: UUID().uuidString)!,
            scope: StorageScope(owner: .member(account: "a", profile: "p"))
        )
        let place = Self.place(Self.posts(3, prefix: "p"), popularLastTime: nil, presence: store)
        place.loadViewIfNeeded()
        place.beginLoading()
        await Self.settle { !place.debugShelf.cards.isEmpty }
        #expect(store.count(screen: "place.Paris", section: "popular") == 3)
    }

    /// A presence store that remembers `following` posts and `friends` faces
    /// from last time (nil: never loaded).
    private static func presence(following: Int?, friends: Int? = nil) -> SectionPresenceStore {
        let store = SectionPresenceStore(
            defaults: UserDefaults(suiteName: UUID().uuidString)!,
            scope: StorageScope(owner: .member(account: "a", profile: "p"))
        )
        if let following { store.remember(following, screen: "foryou", section: "following") }
        if let friends { store.remember(friends, screen: "foryou", section: "friends") }
        return store
    }

    private static func forYou(presence: SectionPresenceStore) -> ForYouViewController {
        ForYouViewController(
            viewModel: ForYouViewModel(repository: EmptyForYouProvider()),
            imagePipeline: ImagePipeline(fetcher: SilentFetcher()),
            makeSnapFeed: { _, _ in UIViewController() },
            prewarm: { _ in },
            presence: presence
        )
    }

    /// ⚠️ #1757: the shelf's skeleton only when the shelf was there last
    /// time — never one that collapses because the shelf turned out empty.
    @Test func forYousFollowingSkeletonFollowsLastKnownPresence() {
        let seen = Self.forYou(presence: Self.presence(following: 7, friends: 4))
        seen.loadViewIfNeeded()
        #expect(seen.debugShelf.isLoading, "a shelf there last time has its skeleton")
        #expect(seen.friendsRow.placeholderCount == 4)

        let empty = Self.forYou(presence: Self.presence(following: 0, friends: 0))
        empty.loadViewIfNeeded()
        #expect(!empty.debugShelf.isLoading, "an empty shelf last time has no skeleton")
        #expect(empty.friendsRow.placeholderCount == 0)

        let unknown = Self.forYou(presence: Self.presence(following: nil))
        unknown.loadViewIfNeeded()
        #expect(!unknown.debugShelf.isLoading, "a shelf never seen fades in rather than shimmer")
    }

    @Test func forYousFollowingLoadsThenDrawsTenAndTheChevron() {
        let screen = Self.forYou(presence: Self.presence(following: 10))
        screen.loadViewIfNeeded()
        let shelf = screen.debugShelf
        #expect(shelf.isLoading, "no skeleton before the first snapshot")
        #expect(shelf.title == "Following")
        var rows = ForYouViewModel.Rails()
        rows.following = Self.posts(14, prefix: "f")
        shelf.apply(.init(title: "Following", posts: rows.following))
        Self.expectLanded(shelf, of: 14)
    }

    @Test func thePlacePagesPopularLoadsThenDrawsTenAndTheChevron() async {
        let place = Self.place(Self.posts(14, prefix: "p"))
        place.loadViewIfNeeded()
        #expect(place.debugShelf.isLoading, "no skeleton before the place's posts")
        place.beginLoading()
        await Self.settle { !place.debugShelf.cards.isEmpty }
        Self.expectLanded(place.debugShelf, of: PlaceProfileViewController.popularRowCount)
    }

    @Test func theLeadRowLoadsThenDrawsTenAndTheChevron() async throws {
        let posts = Self.posts(14, prefix: "r")
        let byID = Dictionary(uniqueKeysWithValues: posts.map { ($0.id, $0) })
        let surface = PostSetSurfaceViewController(
            style: .discover,
            imagePipeline: ImagePipeline(fetcher: SilentFetcher()),
            videoPlayback: nil,
            hydrate: { ids in ids.compactMap { byID[$0] } }
        )
        surface.onLeadRowTitleTapped = {}
        surface.loadViewIfNeeded()
        let shelf = try #require(surface.debugShelf)
        surface.showLeadRow(.posts(posts.map(\.id)))
        #expect(shelf.isLoading, "no skeleton while the posts hydrate")
        await Self.settle { !shelf.cards.isEmpty }
        Self.expectLanded(shelf, of: 14)
    }

    /// ⚠️ #1671 (the owner's screenshot, 2026-10-24): a place with fewer
    /// posts than Popular shows draws them all — and no chevron card.
    @Test func thePlacePagesPopularWithFewPostsHasNoChevron() async {
        let place = Self.place(Self.posts(3, prefix: "p"))
        place.loadViewIfNeeded()
        place.beginLoading()
        await Self.settle { !place.debugShelf.cards.isEmpty }
        Self.expectLandedWhole(place.debugShelf, of: 3)
        #expect(!PlaceProfileViewController.popularShelf(Self.posts(10, prefix: "p")).hasMore)
        #expect(PlaceProfileViewController.popularShelf(Self.posts(11, prefix: "p")).hasMore)
    }

    /// For You's Following rows: cut at their limit, or with a page still to
    /// load, they end on the chevron; showing the whole list, they do not.
    @Test func forYousFollowingEndsOnTheChevronOnlyWithMore() {
        let few = ForYouViewModel.rails(
            following: Self.posts(3, prefix: "f"), followingNew: [], friends: [], friendsUnseen: [],
            limit: 20, rowLimit: 10
        )
        #expect(!few.followingHasMore)
        let many = ForYouViewModel.rails(
            following: Self.posts(14, prefix: "f"), followingNew: [], friends: [], friendsUnseen: [],
            limit: 20, rowLimit: 10
        )
        #expect(many.followingHasMore)
    }

    /// The hashtag's lead row: a few posts and nothing past them draw no
    /// chevron; told its list goes on, the row ends on it, and it pushes.
    @Test func theLeadRowEndsOnTheChevronOnlyWithMore() async throws {
        let posts = Self.posts(3, prefix: "r")
        let byID = Dictionary(uniqueKeysWithValues: posts.map { ($0.id, $0) })
        let surface = PostSetSurfaceViewController(
            style: .discover,
            imagePipeline: ImagePipeline(fetcher: SilentFetcher()),
            videoPlayback: nil,
            hydrate: { ids in ids.compactMap { byID[$0] } }
        )
        var pushed = 0
        surface.onLeadRowTitleTapped = { pushed += 1 }
        surface.loadViewIfNeeded()
        let shelf = try #require(surface.debugShelf)
        surface.showLeadRow(.posts(posts.map(\.id)), hasMore: false)
        await Self.settle { !shelf.cards.isEmpty }
        Self.expectLandedWhole(shelf, of: 3)

        surface.showLeadRow(.posts(posts.map(\.id)), hasMore: true)
        shelf.layoutIfNeeded()
        #expect(shelf.mediaView.numberOfItems(inSection: 0) == 4, "a list that goes on drew no chevron")
        #expect(shelf.debugTapViewAll())
        #expect(pushed == 1, "the chevron did not push the destination")
    }
}
