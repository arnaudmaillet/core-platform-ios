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
@testable import Profile

/// A profile's bare tiles and its gallery's flight draw the post's LIVE count
/// (#896): a like made in the feed a tile opened is on the tile, and on the
/// card that flies from it.
@MainActor
struct ProfileLiveCountTests {
    private struct SilentFetcher: ImageFetching {
        func fetchImageData(for url: URL) async throws -> Data { Data() }
    }

    private actor NoProfiles: ProfileProviding {
        private func someone() -> UserProfile {
            UserProfile(
                id: ProfileID("prof-demo"), handle: "you", displayName: "Demo Viewer",
                bio: "", avatarURL: nil, websiteURL: nil, isVerified: false,
                followerCount: .exact(0), followingCount: .exact(0), reactionCount: .exact(0)
            )
        }
        func currentUserProfile() async throws -> UserProfile { someone() }
        func profile(id: ProfileID) async throws -> UserProfile { someone() }
        func relationship(for profileID: ProfileID) async throws -> ProfileRelationship { .me }
        func setFollowing(_ following: Bool, for profileID: ProfileID) async throws {}
        func setBlocked(_ blocked: Bool, for profileID: ProfileID) async throws {}
        func blockAccount(behind profileID: ProfileID) async throws -> [ProfileID] { [profileID] }
        func updateCurrentUserProfile(
            displayName: String, bio: String, website: String, links: [ProfileLink]
        ) async throws -> UserProfile { someone() }
        func changeHandle(_ newHandle: String) async throws -> UserProfile { someone() }
    }

    private actor NoGallery: ProfileGalleryProviding {
        func authoredPosts(for profileID: ProfileID) async throws -> [GalleryPost] { [] }
        func taggedPosts(for profileID: ProfileID, handle: String) async throws -> [GalleryPost] { [] }
        func posts(ids: [String]) async throws -> [GalleryPost] { [] }
    }

    private static func wallet() -> WalletStore {
        let name = "profile-live-count-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return WalletStore(defaults: defaults)
    }

    private func post(_ index: Int) -> GalleryPost {
        GalleryPost(
            id: PostID("p\(index)"), kind: .photo, isRepost: false,
            thumbnailURL: URL(string: "https://example.com/\(index).jpg"),
            caption: "Post \(index)", publishedAtMS: Int64(10_000 - index), reactionCount: 40
        )
    }

    /// The media mosaic: every post a bare tile.
    private func mosaic(staking: PostCardStaking) -> ForYouGridPage {
        let page = ForYouGridPage(imagePipeline: ImagePipeline(fetcher: SilentFetcher()), style: .grid)
        page.staking = staking
        page.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        page.layoutIfNeeded()
        page.setCorpusComplete(true)
        page.render(.content((0..<12).map(post)))
        page.layoutIfNeeded()
        page.collectionView.layoutIfNeeded()
        return page
    }

    private func tile(_ id: PostID, on page: ForYouGridPage) throws -> PostGridTileCell {
        let path = try #require(page.debugIndexPath(for: id))
        page.collectionView.scrollToItem(at: path, at: .top, animated: false)
        page.collectionView.layoutIfNeeded()
        return try #require(page.collectionView.cellForItem(at: path) as? PostGridTileCell)
    }

    @Test func aBareTileDrawsTheLiveCount() throws {
        let entities = EntityStore()
        let page = mosaic(staking: PostCardStaking(wallet: Self.wallet(), entities: entities))
        let cell = try tile(PostID("p0"), on: page)
        #expect(cell.debugCounterText == "40")
        #expect(entities.post(PostID("p0"))?.likeCount == 40, "the tile told the store its count")

        // Liked in the vertical feed it opened.
        entities.addLikes(1, to: PostID("p0"))

        #expect(cell.debugCounterText == "41")
        #expect(!cell.debugIsStaked, "a bare tile's heart stays as drawn")
    }

    /// The gallery's flight carries the live count, and the tile's stand-in
    /// too: the number does not change in the landing frame.
    @Test func theGalleryFlightAndItsStandInCarryTheLiveCount() throws {
        let entities = EntityStore()
        let staking = PostCardStaking(wallet: Self.wallet(), entities: entities)
        // The profile's pages are For You's (#1273): the open is measured on
        // the page the profile now draws its media on.
        let page = ForYouGridPage(imagePipeline: ImagePipeline(fetcher: SilentFetcher()), style: .grid)
        page.staking = staking
        page.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        page.setCorpusComplete(true)
        page.render(.content((0..<12).map(post)))
        page.layoutIfNeeded()
        page.collectionView.layoutIfNeeded()
        _ = try #require(page.debugCell(for: PostID("p0")) as? PostGridTileCell)
        entities.addLikes(1, to: PostID("p0"))

        let screen = ProfileViewController(
            viewModel: ProfileViewModel(repository: NoProfiles(), gallery: NoGallery(), source: .currentUser),
            imagePipeline: ImagePipeline(fetcher: SilentFetcher()),
            makeGridPage: TestGridPages.factory(),
            onLogout: nil
        )
        screen.staking = staking
        var handed: SnapFeedHeroOrigin?
        screen.feedHero = { _, _, origin in handed = origin }
        screen.openGalleryPost(post(0), stream: [post(0), post(1)], showingComments: false, from: page)

        let origin = try #require(handed)
        #expect(origin.post.reactionCount == 41)
        #expect(origin.stream.map(\.reactionCount) == [41, 40])
        let standIn = try #require(page.makeDismissStandIn(for: PostID("p0")) as? PostGridTileStandInView)
        #expect(standIn.debugCounterText == "41")
    }
}
