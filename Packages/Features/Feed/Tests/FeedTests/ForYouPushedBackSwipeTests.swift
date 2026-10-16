import CoreModels
import CoreNavigation
import MediaCore
import PostGrid
import Testing
import UIKit
@testable import Feed

/// For You's pushed galleries go back with a swipe (#670): Discover's mosaic and
/// the Following and Friends lists.
///
/// A real finger cannot be synthesised here, so what is pinned is what the
/// stack's two back-swipe recognisers decide on:
/// - the vended edge recogniser's begin decision, `NativePopPolicy`, fed what
///   the screen reports (`NativePopGestureEnabler` asks exactly this);
/// - the full-surface recogniser's precondition, measured on the simulator: an
///   EMPTY delegate slot. With any delegate there, UIKit refused its touch on
///   these screens, whose pop brings the tab bar back, after one post had been
///   opened and closed from For You.
@MainActor
struct ForYouPushedBackSwipeTests {
    private struct SilentFetcher: ImageFetching {
        func fetchImageData(for url: URL) async throws -> Data { Data() }
    }

    private static func screens() -> [(name: String, screen: UIViewController)] {
        let header = { PushedScreenHeader(wallet: nil, makeWalletSheet: nil, router: nil) }
        let pipeline = ImagePipeline(fetcher: SilentFetcher())
        return [
            ("Discover mosaic", DiscoverGalleryViewController(
                imagePipeline: pipeline, videoPlayback: nil, header: header(), openPost: nil
            )),
            ("Following list", ForYouPostListViewController(
                kind: .following, imagePipeline: pipeline, videoPlayback: nil, staking: nil,
                header: header(), openPost: nil
            )),
            ("Friends list", ForYouPostListViewController(
                kind: .friends, imagePipeline: pipeline, videoPlayback: nil, staking: nil,
                header: header(), openPost: nil
            ))
        ]
    }

    /// The edge recogniser may begin: not a root, a back affordance of UIKit's
    /// own, not a hero destination that owns its dismissal.
    @Test func theEdgeSwipeIsAllowedOnEveryPushedGallery() {
        for (name, screen) in Self.screens() {
            let nav = UINavigationController(rootViewController: UIViewController())
            nav.pushViewController(screen, animated: false)
            screen.loadViewIfNeeded()
            let item = screen.navigationItem
            #expect(NativePopPolicy.shouldBegin(
                isAtRoot: nav.viewControllers.count <= 1,
                isTransitioning: false,
                hidesBackButton: item.hidesBackButton,
                ownsInteractiveDismissal: (screen as? any ZoomTransitionDestination)?.zoomOwnsInteractiveDismissal,
                hasCustomLeadingItem: item.leftBarButtonItem != nil,
                leadingItemsSupplementBackButton: item.leftItemsSupplementBackButton
            ), "\(name): the edge swipe would be refused")
        }
    }

    /// After a post opened and closed from For You, the stack's delegate slot
    /// is empty again by the time a gallery is pushed, so UIKit lets the
    /// full-surface swipe begin.
    @Test func aClosedFlightLeavesTheDelegateSlotEmptyForTheGalleries() {
        for (name, screen) in Self.screens() {
            let nav = UINavigationController(rootViewController: UIViewController())
            var flight: FlightStandIn? = FlightStandIn()
            NavigationDelegateHub.of(nav).lease(flight!)
            // The flight's owner lets it go without a release, as For You's does…
            flight = nil
            // …and the close's `didShow` is the first news the hub gets.
            nav.delegate?.navigationController?(nav, didShow: nav.topViewController!, animated: true)

            nav.pushViewController(screen, animated: false)

            #expect(nav.delegate == nil, "\(name): a delegate in the slot costs the full-surface back swipe")
        }
    }
}

private final class FlightStandIn: NSObject, UINavigationControllerDelegate {
    func navigationController(
        _ navigationController: UINavigationController,
        animationControllerFor operation: UINavigationController.Operation,
        from fromVC: UIViewController, to toVC: UIViewController
    ) -> (any UIViewControllerAnimatedTransitioning)? {
        nil
    }
}

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
            loadPosts: { [post] }, openPost: { _, _, _ in }
        )
        let header = { PushedScreenHeader(wallet: nil, makeWalletSheet: nil, router: nil) }
        place.makePostList = {
            ForYouPostListViewController(
                kind: .popular, imagePipeline: pipeline, videoPlayback: nil, staking: nil,
                header: header(), openPost: nil
            )
        }
        place.makeGallery = {
            DiscoverGalleryViewController(imagePipeline: pipeline, videoPlayback: nil, header: header(), openPost: nil)
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
