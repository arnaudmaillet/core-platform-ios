import CoreModels
import CoreStorage
import PlaceInterface
import Foundation
import MediaCore
import MediaPlayback
import PostGrid
import Testing
import UIKit
@testable import Place
@testable import PostSurfaces

/// #951 on the place page (#2381): a tile opened playing parks its clip for
/// a close that pages on and comes home, and a Popular card keeps the tile
/// contract (#1271). The other surfaces are pinned in Feed
/// (`ReturnPlayersEverywhereTests`).
@MainActor
struct PlaceReturnPlayersTests {
    private struct SilentFetcher: ImageFetching {
        func fetchImageData(for url: URL) async throws -> Data { Data() }
    }

    private struct FixedVideoSource: VideoSource {
        let url: URL
        func playableURL(for url: URL) async throws -> URL { self.url }
    }

    private static func makePool() -> VideoPlaybackController {
        VideoPlaybackController(source: FixedVideoSource(
            url: FileManager.default.temporaryDirectory.appendingPathComponent("return-everywhere.mp4")
        ))
    }

    /// Portrait clips, so a mosaic brick autoplays as well as a row.
    private static func videos(_ count: Int = 8, prefix: String = "v") -> [GalleryPost] {
        (0..<count).map { index in
            GalleryPost(
                id: PostID("\(prefix)\(index)"), kind: .video, isRepost: false,
                thumbnailURL: URL(string: "https://example.test/\(prefix)\(index).jpg"),
                videoURL: URL(string: "mock://video/\(prefix)\(index)"),
                aspectRatio: 0.75, caption: "clip \(index)", publishedAtMS: 0
            )
        }
    }

    /// The app-wide autoplay gate is another suite's to set
    /// (`FeedFeatureBuilder` points it at the playback policy); a tile can only
    /// be playing once it allows it.
    private static func whenAutoplayIsAllowed() async {
        for _ in 0..<1_000 where !GridVideoPlaybackCoordinator.allowsAutoplay() {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    private static func settle(_ condition: () -> Bool) async {
        await whenAutoplayIsAllowed()
        for _ in 0..<1_000 {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    @Test func thePlacePageWiresTheReturn() async throws {
        let posts = Self.videos(12)
        var opened: SnapFeedHeroOrigin?
        let place = PlaceProfileViewController(
            postIDs: posts.map(\.id),
            placeName: "Paris • City Cluster",
            rank: nil,
            imagePipeline: ImagePipeline(fetcher: SilentFetcher()),
            videoPlayback: Self.makePool(),
            following: nil,
            wallet: nil,
            loadPosts: { posts },
            presence: SectionPresenceStore(scope: StorageScope()),
            bookmarks: PostBookmarkStore(scope: StorageScope()),
            withheldPosts: UnavailablePosts(),
            openPost: { _, origin, _ in opened = origin }
        )
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        window.rootViewController = UINavigationController(rootViewController: place)
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        // The builder starts the hydration at creation, not on appearance.
        place.beginLoading()
        await Self.settle {
            window.layoutIfNeeded()
            return place.debugOpenTile(at: 0) && opened != nil
        }
        try Self.expectReturnWired(opened)
    }

    // MARK: - A shelf's cards, on every host (#1271)

    /// ⚠️ A SHELF'S CARD IS A TILE UNDER #1269'S CONTRACT, on every screen
    /// that hosts one: it takes off playing, a same-post close continues its
    /// playhead, a close from another post comes home to its own parked clip,
    /// and the words fade in over it at rest. The origin is built by the
    /// SHELF (`PostShelfSection.openCard`), so a host can no longer forget a
    /// hook.
    private static func expectShelfTileContract(_ origin: SnapFeedHeroOrigin?) throws {
        let origin = try #require(origin, "the shelf's tap never reached the shared flight")
        #expect(origin.donateLiveMedia != nil, "the card does not take off playing")
        #expect(origin.adoptLandingLiveMedia != nil, "a same-post close restarts the clip")
        #expect(origin.landingMediaIsReady != nil)
        #expect(origin.returnLiveMedia != nil, "a close from another post lands on a still")
        #expect(origin.pauseReturnLiveMedia != nil)
        #expect(origin.restingOverlay != nil, "the words do not fade in over the card")
        #expect(origin.textReveal != nil, "no window for a close from a text page")
    }

    @Test func thePlacePagesPopularCardsKeepTheTileContract() async throws {
        let posts = Self.videos(12, prefix: "p")
        var opened: SnapFeedHeroOrigin?
        let place = PlaceProfileViewController(
            postIDs: posts.map(\.id),
            placeName: "Paris • City Cluster",
            rank: nil,
            imagePipeline: ImagePipeline(fetcher: SilentFetcher()),
            videoPlayback: Self.makePool(),
            following: nil,
            wallet: nil,
            loadPosts: { posts },
            presence: SectionPresenceStore(scope: StorageScope()),
            bookmarks: PostBookmarkStore(scope: StorageScope()),
            withheldPosts: UnavailablePosts(),
            openPost: { _, origin, _ in opened = origin }
        )
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        window.rootViewController = UINavigationController(rootViewController: place)
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        place.beginLoading()
        await Self.settle {
            window.layoutIfNeeded()
            return place.debugOpenPopularCard(at: 0) && opened != nil
        }
        try Self.expectShelfTileContract(opened)
    }

    private static func expectReturnWired(_ origin: SnapFeedHeroOrigin?) throws {
        let origin = try #require(origin, "the tap never reached the shared flight")
        #expect(origin.returnLiveMedia != nil)
        #expect(origin.pauseReturnLiveMedia != nil)
        #expect(origin.adoptReturnLiveMedia != nil)
        #expect(origin.returnLandingIsReady != nil)
        // ⚠️ AND A SAME-POST CLOSE CONTINUES THE PLAYHEAD (#1270, epic
        // #1269): the tile takes the surface the card flew, as For You's own
        // tiles do — these used to restart the clip.
        #expect(origin.adoptLandingLiveMedia != nil)
        #expect(origin.landingMediaIsReady != nil)
    }
}
