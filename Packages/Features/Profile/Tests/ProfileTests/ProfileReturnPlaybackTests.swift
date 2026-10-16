import CoreModels
import FeedInterface
import Foundation
import MediaCore
import MediaPlayback
import PostGrid
import Testing
import UIKit
@testable import Feed
@testable import Profile

/// #951 on the profile, through the screen's open: the round trip's scope
/// ends when an open is refused, and the open hands the shared flight the
/// whole tile contract (#1273). The page's own parking and landing are For
/// You's, pinned in Feed (`ReturnPlayersEverywhereTests`).
@MainActor
struct ProfileReturnPlaybackTests {
    private struct SilentFetcher: ImageFetching {
        func fetchImageData(for url: URL) async throws -> Data { Data() }
    }

    private struct FixedVideoSource: VideoSource {
        let url: URL
        func playableURL(for url: URL) async throws -> URL { self.url }
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

    /// Portrait clips, so every brick of the media mosaic autoplays.
    private func videos(_ count: Int = 12) -> [GalleryPost] {
        (0..<count).map { index in
            GalleryPost(
                id: PostID("pv\(index)"), kind: .video, isRepost: false,
                thumbnailURL: URL(string: "https://example.test/pv\(index).jpg"),
                videoURL: URL(string: "mock://video/pv\(index)"),
                aspectRatio: 0.75, caption: "clip \(index)", publishedAtMS: Int64(10_000 - index)
            )
        }
    }

    /// The page the profile draws its media on (#1273): For You's, with the
    /// app's pool.
    private func forYouGallery(pool: VideoPlaybackController? = nil) -> (ForYouGridPage, [GalleryPost]) {
        let page = ForYouGridPage(imagePipeline: ImagePipeline(fetcher: SilentFetcher()), style: .grid, videoPlayback: pool)
        page.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        page.setCorpusComplete(true)
        let posts = videos()
        page.render(.content(posts))
        page.layoutIfNeeded()
        page.collectionView.layoutIfNeeded()
        return (page, posts)
    }

    /// ⚠️ A REFUSED OPEN pushes nothing, and the screen never disappears to end
    /// the scope it opened: the grid would sit silent. The open closes it at
    /// once; a real push keeps it for the trip.
    @Test func aRefusedOpenClosesTheScopeAndAPushKeepsIt() throws {
        let pool = VideoPlaybackController(source: FixedVideoSource(
            url: FileManager.default.temporaryDirectory.appendingPathComponent("profile-return.mp4")
        ))
        let (page, posts) = forYouGallery(pool: pool)
        let tapped = try #require(posts.first)
        let screen = ProfileViewController(
            viewModel: ProfileViewModel(repository: NoProfiles(), gallery: NoGallery(), source: .currentUser),
            imagePipeline: ImagePipeline(fetcher: SilentFetcher()),
            makeGridPage: TestGridPages.factory(),
            onLogout: nil
        )
        let navigation = UINavigationController(rootViewController: screen)

        screen.feedHero = { _, _, _ in }
        screen.openGalleryPost(tapped, stream: [tapped], showingComments: false, from: page)
        #expect(page.playback?.isHandingOff == false, "a refused open left the grid's scope open")

        screen.feedHero = { _, _, _ in navigation.pushViewController(UIViewController(), animated: false) }
        screen.openGalleryPost(tapped, stream: [tapped], showingComments: false, from: page)
        #expect(page.playback?.isHandingOff == true, "a real open lost its scope")
    }

    /// ⚠️ The profile's open hands the shared flight the WHOLE tile contract
    /// (#1273, epic #1269): the return path, and the landing's playhead — a
    /// same-post close used to restart the tile's clip.
    @Test func theProfilesOpenWiresTheReturnAndThePlayhead() throws {
        let (page, posts) = forYouGallery()
        let screen = ProfileViewController(
            viewModel: ProfileViewModel(repository: NoProfiles(), gallery: NoGallery(), source: .currentUser),
            imagePipeline: ImagePipeline(fetcher: SilentFetcher()),
            makeGridPage: TestGridPages.factory(),
            onLogout: nil
        )
        var handed: SnapFeedHeroOrigin?
        screen.feedHero = { _, _, origin in handed = origin }
        screen.openGalleryPost(posts[0], stream: posts, showingComments: false, from: page)
        let origin = try #require(handed, "the open never reached the hero seam")
        #expect(origin.donateLiveMedia != nil, "the tile takes off as a still")
        #expect(origin.returnLiveMedia != nil)
        #expect(origin.pauseReturnLiveMedia != nil)
        #expect(origin.adoptReturnLiveMedia != nil)
        #expect(origin.returnLandingIsReady != nil)
        #expect(origin.adoptLandingLiveMedia != nil, "a same-post close restarts the clip")
        #expect(origin.landingMediaIsReady != nil)
    }
}
