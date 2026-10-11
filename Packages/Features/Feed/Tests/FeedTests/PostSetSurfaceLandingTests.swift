import CoreModels
import FeedInterface
import Foundation
import MediaCore
import PostGrid
import Testing
import UIKit
@testable import Feed

/// Where a close from the search results' post grid lands (#883).
///
/// The surface is a CHILD of the search results screen (a page of its pager),
/// pushed over by the post it opens. A close puts that screen back under the
/// flight's depth recede — the grid scaled to 0.95 about its centre — while
/// the pop brings the screen's chrome back. An unpinned grid then re-resolved
/// its safe area from its SCALED frame (2.5% of its height in from each
/// edge), its inset and offset followed, and every tile slid 22pt up under
/// the card: the card came down above the tile, and the tile dropped into
/// place once the screen was back. For You's own grid is pinned by its flight
/// source as the close stages; these pin the search grid the same way.
@MainActor
struct PostSetSurfaceLandingTests {
    /// `ZoomFlight.presenterDepthScale`, internal to CoreNavigation.
    private static let depthScale: CGFloat = 0.95

    /// The search results' arrangement: a navigation stack whose top is a
    /// screen hosting the surface as a child, in a phone-sized window.
    @MainActor
    private final class Stage {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        let navigation: UINavigationController
        let screen = UIViewController()
        let surface: PostSetSurfaceViewController

        init() {
            let ids = (1...8).map { "p\($0)" }
            let byID = ids.reduce(into: [PostID: GalleryPost]()) { map, id in
                map[PostID(id)] = GalleryPost(
                    id: PostID(id), kind: .photo, isRepost: false, thumbnailURL: nil,
                    caption: id, publishedAtMS: 0, reactionCount: nil
                )
            }
            surface = PostSetSurfaceViewController(
                style: .discover,
                imagePipeline: ImagePipeline(fetcher: PlaceholderImageFetcher()),
                videoPlayback: nil,
                hydrate: { ids in ids.compactMap { byID[$0] } }
            )
            screen.addChild(surface)
            surface.view.frame = screen.view.bounds
            surface.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            screen.view.addSubview(surface.view)
            surface.didMove(toParent: screen)
            navigation = UINavigationController(rootViewController: UIViewController())
            navigation.pushViewController(screen, animated: false)
            window.rootViewController = navigation
            window.makeKeyAndVisible()
            window.layoutIfNeeded()
            surface.show(.posts(ids.map { PostID($0) }))
        }

        /// The grab's landing read (`ZoomDismissInteractionController
        /// .currentLanding`): the depth view momentarily at identity, which is
        /// the space the card's own frame lives in.
        func landing(_ origin: SnapFeedHeroOrigin) -> CGRect? {
            let depth = origin.depthView()
            let recede = depth?.transform ?? .identity
            depth?.transform = .identity
            defer { depth?.transform = recede }
            return origin.frame(window)
        }
    }

    private func settleUntil(_ condition: () -> Bool) async {
        for _ in 0..<2_000 {
            await Task.yield()
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    /// Opens item `index` through the page's selection path, the one a finger
    /// reaches. `push` decides whether the opener covers the screen with a
    /// stand-in feed, as the real one does, or refuses.
    private func open(
        _ index: Int, on stage: Stage, push: Bool
    ) async -> (origin: SnapFeedHeroOrigin, rest: CGRect)? {
        var opened: (SnapFeedHeroOrigin, CGRect)?
        stage.surface.openPost = { _, origin, _ in
            opened = (origin, origin.frame(stage.window) ?? .null)
            if push { stage.navigation.pushViewController(UIViewController(), animated: false) }
        }
        await settleUntil {
            stage.window.layoutIfNeeded()
            return stage.surface.debugOpenTile(at: index) && opened != nil
        }
        stage.window.layoutIfNeeded()
        return opened
    }

    @Test("A close from the search grid lands on the tile it left, through the depth recede")
    func theLandingIsTheTile() async throws {
        let stage = Stage()
        // No push: the inset is not held from the tap, so only the close's
        // own staging stands between the grid and the drift.
        let opened = try #require(await open(1, on: stage, push: false))
        #expect(!opened.rest.isNull && opened.rest.minY > 0, "no tile to land on")
        #expect(stage.screen.view.safeAreaInsets.top > 30, "no top inset to lose")

        // The flight's close: the source stages, the depth view recedes, and
        // the pop brings the screen's bottom chrome back (the search results'
        // band: 34 → 76), which re-resolves the scaled grid's safe area.
        opened.origin.willStageDismissal()
        opened.origin.depthView()?.transform = CGAffineTransform(
            scaleX: Self.depthScale, y: Self.depthScale
        )
        stage.screen.additionalSafeAreaInsets.bottom = 42
        stage.window.layoutIfNeeded()

        let landing = try #require(stage.landing(opened.origin))
        #expect(abs(landing.minY - opened.rest.minY) <= 1,
                "landed \(landing.minY - opened.rest.minY)pt off the tile")
        #expect(abs(landing.minX - opened.rest.minX) <= 1)
        #expect(abs(landing.size.height - opened.rest.size.height) <= 1)
    }

    @Test("The grid holds still under the post from the tap until the screen is back")
    func theGridIsPinnedForTheVisit() async throws {
        let stage = Stage()
        let opened = try #require(await open(1, on: stage, push: true))
        #expect(stage.surface.debugIsGridInsetPinned, "a covered grid tracking the safe area")

        stage.navigation.popViewController(animated: false)
        stage.window.layoutIfNeeded()
        #expect(!stage.surface.debugIsGridInsetPinned, "the inset never came back")
        let back = try #require(opened.origin.frame(stage.window))
        #expect(abs(back.minY - opened.rest.minY) <= 1, "the tile moved \(back.minY - opened.rest.minY)pt")
    }
}
