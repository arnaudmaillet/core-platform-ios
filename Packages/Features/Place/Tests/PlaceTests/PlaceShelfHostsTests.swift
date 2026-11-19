import CoreStorage
import CoreModels
import PlaceInterface
import Foundation
import MediaCore
import PostGrid
import Testing
import UIKit
@testable import Place
@testable import PostSurfaces

/// Every host of a shelf (#1296, the owner 2026-10-16): its title over
/// skeleton cards until its posts land, then ten cards a row at most — a row
/// ending on the chevron card that runs "View all" only when its list holds
/// more than it shows (#1671, the owner 2026-10-24).
@MainActor
struct PlaceShelfHostsTests {
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
            presence: store, bookmarks: PostBookmarkStore(scope: StorageScope()), withheldPosts: UnavailablePosts(),
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

    @Test func thePlacePagesPopularLoadsThenDrawsTenAndTheChevron() async {
        let place = Self.place(Self.posts(14, prefix: "p"))
        place.loadViewIfNeeded()
        #expect(place.debugShelf.isLoading, "no skeleton before the place's posts")
        place.beginLoading()
        await Self.settle { !place.debugShelf.cards.isEmpty }
        Self.expectLanded(place.debugShelf, of: PlaceProfileViewController.popularRowCount)
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
}
