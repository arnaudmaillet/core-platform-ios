import CoreModels
import FeedInterface
import Foundation
import MediaCore
import MediaPlayback
import PostGrid
import Testing
import UIKit
@testable import Profile

/// #951 on the profile's gallery: the tap parks the tile's clip, a close from
/// another post lands it back on the tile, and the round trip's scope ends
/// when the screen is the viewer's again.
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

    private static func picture() -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4)).image { context in
            UIColor.systemTeal.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        }
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

    private func settle(_ condition: () -> Bool) async {
        for _ in 0..<1_000 {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    /// The media mosaic in a window, its first tile playing.
    private func playingGallery(
        pool: VideoPlaybackController
    ) async throws -> (page: ProfileGalleryGridView, tapped: GalleryPost, tile: VideoRenderView, window: UIWindow) {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        let page = ProfileGalleryGridView(
            imagePipeline: ImagePipeline(fetcher: SilentFetcher()),
            style: .grid, tab: .format(.media), videoPlayback: pool
        )
        page.frame = window.bounds
        window.addSubview(page)
        window.isHidden = false
        page.layoutIfNeeded()
        page.setCorpusComplete(true)
        let posts = videos()
        page.render(.content(posts))
        page.layoutIfNeeded()
        page.collectionView.layoutIfNeeded()
        for cell in page.collectionView.visibleCells {
            (cell as? any GridPlaybackCell)?.applyCover(Self.picture())
        }
        page.setAutoplayActive(true)
        // The tile a finger would tap: one that is playing — which ones the
        // ranking chose is the page's business.
        func playing() -> (GalleryPost, VideoRenderView)? {
            for post in posts {
                guard let path = page.debugIndexPath(for: post.id),
                      let surface = (page.collectionView.cellForItem(at: path) as? any GridPlaybackCell)?
                        .loadedVideoRenderView,
                      pool.hasPlayer(in: surface)
                else { continue }
                return (post, surface)
            }
            return nil
        }
        // Reconciled again until it takes: the app-wide autoplay gate is other
        // suites' to flip, and a reconcile is idempotent.
        await settle {
            page.setAutoplayActive(true)
            return playing() != nil
        }
        let (tapped, tile) = try #require(playing(), "precondition: a tile is playing")
        return (page, tapped, tile, window)
    }

    @Test func theTapParksTheTilesClipAndStopsItsOwnPlayer() async throws {
        let pool = VideoPlaybackController(source: FixedVideoSource(
            url: FileManager.default.temporaryDirectory.appendingPathComponent("profile-return.mp4")
        ))
        let (page, tapped, tile, window) = try await playingGallery(pool: pool)
        defer { window.isHidden = true }

        page.beginReturnHandoff(of: tapped.id)
        #expect(!pool.hasPlayer(in: tile), "the tapped tile kept decoding behind the feed")
        await settle { pool.returnPlaybackCount == 1 }
        #expect(pool.returnPlaybackCount == 1, "the tap parked nothing")
        page.setAutoplayActive(false)

        let flying = try #require(page.returnFlightSurface(for: tapped.id))
        #expect(page.landReturnPlayback(flying, for: tapped.id))
        #expect(pool.returnPlaybackCount == 0, "the landing did not claim the parked player")
        #expect(pool.hasPlayer(in: tile))

        // The screen is the viewer's again: the scope ends and the tile keeps
        // the clip it landed.
        page.setAutoplayActive(true)
        #expect(pool.hasPlayer(in: tile))
    }

    /// Nothing parked: the close lands on the still, and the hold waits for it
    /// alone; the scope's end releases a player nobody landed.
    @Test func withNothingParkedTheCloseLandsOnTheStill() async throws {
        let pool = VideoPlaybackController(source: FixedVideoSource(
            url: FileManager.default.temporaryDirectory.appendingPathComponent("profile-return.mp4")
        ))
        let (page, tapped, _, window) = try await playingGallery(pool: pool)
        defer { window.isHidden = true }
        page.beginReturnHandoff(of: tapped.id)
        await settle { pool.returnPlaybackCount == 1 }
        page.setAutoplayActive(false)
        page.setAutoplayActive(true)
        #expect(pool.returnPlaybackCount == 0, "an unused return player outlived the trip")
        #expect(page.returnFlightSurface(for: tapped.id) == nil)
        #expect(page.isReturnLandingReady(for: tapped.id))
    }

    /// ⚠️ A REFUSED OPEN pushes nothing, and the screen never disappears to end
    /// the scope it opened: the grid would sit silent. The open closes it at
    /// once; a real push keeps it for the trip.
    @Test func aRefusedOpenClosesTheScopeAndAPushKeepsIt() async throws {
        let pool = VideoPlaybackController(source: FixedVideoSource(
            url: FileManager.default.temporaryDirectory.appendingPathComponent("profile-return.mp4")
        ))
        let (page, tapped, _, window) = try await playingGallery(pool: pool)
        defer { window.isHidden = true }
        let screen = ProfileViewController(
            viewModel: ProfileViewModel(repository: NoProfiles(), gallery: NoGallery(), source: .currentUser),
            imagePipeline: ImagePipeline(fetcher: SilentFetcher()),
            onLogout: nil
        )
        let navigation = UINavigationController(rootViewController: screen)

        screen.feedHero = { _, _, _ in }
        screen.openGalleryPost(tapped, stream: [tapped], showingComments: false, from: page)
        #expect(!page.debugIsHandingOff, "a refused open left the grid's scope open")

        screen.feedHero = { _, _, _ in navigation.pushViewController(UIViewController(), animated: false) }
        screen.openGalleryPost(tapped, stream: [tapped], showingComments: false, from: page)
        #expect(page.debugIsHandingOff, "a real open lost its scope")
    }

    /// The profile's open hands the shared flight the return path — and only
    /// that: same-post closes adopt nothing, as before.
    @Test func theProfilesOpenWiresTheReturn() throws {
        let page = ProfileGalleryGridView(
            imagePipeline: ImagePipeline(fetcher: SilentFetcher()), style: .grid, tab: .format(.media)
        )
        page.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        page.layoutIfNeeded()
        page.setCorpusComplete(true)
        let posts = videos()
        page.render(.content(posts))
        page.layoutIfNeeded()
        page.collectionView.layoutIfNeeded()

        let screen = ProfileViewController(
            viewModel: ProfileViewModel(repository: NoProfiles(), gallery: NoGallery(), source: .currentUser),
            imagePipeline: ImagePipeline(fetcher: SilentFetcher()),
            onLogout: nil
        )
        var handed: SnapFeedHeroOrigin?
        screen.feedHero = { _, _, origin in handed = origin }
        screen.openGalleryPost(posts[0], stream: posts, showingComments: false, from: page)
        let origin = try #require(handed, "the open never reached the hero seam")
        #expect(origin.returnLiveMedia != nil)
        #expect(origin.pauseReturnLiveMedia != nil)
        #expect(origin.adoptReturnLiveMedia != nil)
        #expect(origin.returnLandingIsReady != nil)
        #expect(origin.adoptLandingLiveMedia == nil)
    }
}
