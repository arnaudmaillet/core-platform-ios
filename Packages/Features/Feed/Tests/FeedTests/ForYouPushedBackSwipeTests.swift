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
