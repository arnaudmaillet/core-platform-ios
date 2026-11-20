import CoreModels
import CoreNavigation
import CoreStorage
import MediaCore
import PostGrid
import Testing
import Transitions
import UIKit
@testable import Place
@testable import PostSurfaces

/// The place page's pushed screens go back with a full-surface swipe too (the
/// owner, 2026-10-16): the page holds the delegate slot with its way home to
/// the map while it is top, and gives it up for a plain push.
@MainActor
struct PlacePushedBackSwipeTests {
    private struct SilentFetcher: ImageFetching {
        func fetchImageData(for url: URL) async throws -> Data { Data() }
    }

    @Test(arguments: ["Popular", "Recent"])
    func aPushFromThePlacePageLeavesTheDelegateSlotEmpty(title: String) async throws {
        let pipeline = ImagePipeline(fetcher: SilentFetcher())
        let post = GalleryPost(
            id: PostID("p1"), kind: .photo, isRepost: false, thumbnailURL: nil,
            caption: "", publishedAtMS: 0, reactionCount: 3
        )
        let place = PlaceProfileViewController(
            postIDs: [post.id], placeName: "Paris • City Cluster",
            imagePipeline: pipeline, videoPlayback: nil,
            loadPosts: { [post] },
            presence: SectionPresenceStore(scope: StorageScope()),
            bookmarks: PostBookmarkStore(scope: StorageScope()),
            withheldPosts: UnavailablePosts(viewerEvents: ViewerEvents()), openPost: { _, _, _ in }
        )
        let header = { PushedScreenHeader(wallet: nil, makeWalletSheet: nil, router: nil) }
        place.makePostList = {
            PushedPostListViewController(
                kind: .popular, imagePipeline: pipeline, videoPlayback: nil,
                bookmarks: PostBookmarkStore(scope: StorageScope()),
                withheldPosts: UnavailablePosts(viewerEvents: ViewerEvents()), staking: nil,
                header: header(), openPost: nil
            )
        }
        place.makeGallery = {
            DiscoverGalleryViewController(imagePipeline: pipeline, videoPlayback: nil,
            bookmarks: PostBookmarkStore(scope: StorageScope()),
            withheldPosts: UnavailablePosts(viewerEvents: ViewerEvents()), header: header(), openPost: nil)
        }
        // The map's window close, as the map hands it over.
        place.markerClose = { (_: UIViewController) -> RevealGeometry? in nil }
        let nav = UINavigationController(rootViewController: UIViewController())
        nav.pushViewController(place, animated: false)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        window.rootViewController = nav
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        place.beginLoading()
        for _ in 0..<200 where place.renderedActivity.isEmpty { try? await Task.sleep(for: .milliseconds(5)) }
        // Top: the page leases its way home, as `viewDidAppear` does.
        place.viewDidAppear(false)
        try #require(nav.delegate != nil, "precondition: the page holds the slot while it is top")

        if title == "Popular" { place.debugTapPopularTitle() } else { place.debugTapRecentTitle() }

        #expect(nav.viewControllers.count == 3, "the title pushed nothing")
        #expect(nav.delegate == nil, "a delegate in the slot costs the pushed screen its full-surface back swipe")
    }
}
