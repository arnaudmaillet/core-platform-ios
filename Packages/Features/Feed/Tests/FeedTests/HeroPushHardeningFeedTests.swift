import CoreModels
import CoreNavigation
import FeedInterface
import MediaCore
import PostGrid
import Testing
import UIKit
@testable import Feed

/// The Feed side of the hero push hardening (`dev/HERO_PUSH_AUDIT_PLAN.md`,
/// Phase 1): what an opening through `presentSnapFeedHero` leaves behind when
/// it does not end the ordinary way, and what a REUSED feed inherits from the
/// visit before.
@MainActor
struct HeroPushHardeningFeedTests {

    // MARK: - 1.4 A reversed push closes out like a return

    /// A push caught mid-air and dragged back completes nothing, so `didShow`
    /// never reports it and only `onPresentationCancelled` hears it. That
    /// closure used to restore the dock and nothing else: the stack's delegate
    /// stayed on the dead flight (which the next opening then captured as the
    /// one to restore), and the transition, its source and its card close
    /// leaked through the retainer cycle.
    @Test func aReversedPushHandsTheStackBackAndReleasesTheFlight() async throws {
        let stack = Stack()
        stack.builder.presentSnapFeedHero(
            postIDs: [PostID("m1")], from: stack.presenter, origin: Self.origin(reveal: Self.reveal())
        )
        weak let transition = ZoomTransitionController.debugMostRecent
        #expect(transition != nil)
        #expect(stack.nav.leasedDelegate is InteractiveSlideDismissal, "precondition: the card close holds the slot")

        transition?.onPresentationCancelled?()

        #expect(stack.nav.leasedDelegate == nil, "the stack's delegate stayed on a flight that never showed")
        // Released a turn later by design (the close-out may run inside one
        // of these objects' own callbacks).
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(transition == nil, "the reversed flight's controller leaked")
    }

    // MARK: - 1.19 One opening at a time

    @Test func onlyTheScreenOnTopOfAStackAtRestMayOpen() {
        let presenter = UIViewController()
        let child = UIViewController()
        presenter.addChild(child)
        let nav = UINavigationController(rootViewController: presenter)

        #expect(FeedFeatureBuilder.canOpen(from: presenter, on: nav))
        #expect(FeedFeatureBuilder.canOpen(from: child, on: nav), "a grid hosted inside the top screen may open")

        nav.pushViewController(UIViewController(), animated: false)
        #expect(!FeedFeatureBuilder.canOpen(from: presenter, on: nav), "a covered screen opened over the one on top")
    }

    // MARK: - The reused feed starts clean

    /// 1.13 (the feed's half): whatever a previous visit's flight left, a
    /// re-pointed feed is visible.
    @Test func aRepointedFeedIsVisible() {
        let feed = Self.feed()
        feed.view.alpha = 0
        #expect(feed.repoint(to: [PostID("m2")]))
        #expect(feed.view.alpha == 1, "the reused feed kept the last flight's hide")
    }

    /// 1.17: the reveal installer builds a CLOSE's geometry too, while the
    /// feed is on screen. Only an opening — the feed not yet in a window —
    /// marks a presentation pending.
    @Test func aCloseStagingIsNotReadAsAPresentation() {
        let opening = Self.feed()
        opening.beginRevealPresentation()
        #expect(opening.isAwaitingRevealPresentation, "an opening must still be recorded")

        let onScreen = Self.feed()
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        window.rootViewController = onScreen
        window.isHidden = false
        defer { window.isHidden = true }
        onScreen.beginRevealPresentation()
        #expect(!onScreen.isAwaitingRevealPresentation, "a close staging was read as a presentation")
    }

    // MARK: - Fixtures

    private static func feed() -> SnapFeedViewController {
        let builder = FeedFeatureBuilder(
            repository: SilentProvider(),
            imagePipeline: ImagePipeline(fetcher: PlaceholderImageFetcher())
        )
        return builder.makeSnapFeedViewController(postIDs: [PostID("m1")]) as! SnapFeedViewController
    }

    private static func reveal() -> TextRevealOrigin {
        TextRevealOrigin(
            rowFrame: { _ in CGRect(x: 16, y: 300, width: 370, height: 140) },
            captionEnd: nil,
            pageFit: .covering,
            setConcealed: { _ in },
            dismissalDidEnd: { _ in }
        )
    }

    private static func origin(reveal: TextRevealOrigin?) -> SnapFeedHeroOrigin {
        let post = GalleryPost(
            id: PostID("m1"), kind: .video, isRepost: false,
            thumbnailURL: nil, caption: "a caption", publishedAtMS: 0
        )
        return SnapFeedHeroOrigin(
            post: post, stream: [post], hasHero: true, cover: nil, style: .listMedia,
            frame: { _ in CGRect(x: 0, y: 0, width: 100, height: 100) },
            isOnScreen: { true },
            setConcealed: { _ in },
            textReveal: reveal
        )
    }

    @MainActor
    private final class Stack {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        let presenter = UIViewController()
        let nav: UINavigationController
        let tabs = UITabBarController()
        let builder = FeedFeatureBuilder(
            repository: SilentProvider(),
            imagePipeline: ImagePipeline(fetcher: PlaceholderImageFetcher())
        )

        init() {
            nav = UINavigationController(rootViewController: presenter)
            tabs.viewControllers = [nav]
            window.rootViewController = tabs
            window.isHidden = false
            window.layoutIfNeeded()
        }
    }
}

private struct SilentProvider: FeedProviding {
    func cachedFirstPage() async -> [FeedEntry]? { nil }
    func loadFirstPage() async throws -> FeedPage {
        try? await Task.sleep(nanoseconds: 5_000_000_000)
        return FeedPage(entries: [], nextPageToken: nil, isCold: false)
    }
    func loadPage(afterToken token: String) async throws -> FeedPage {
        FeedPage(entries: [], nextPageToken: nil, isCold: false)
    }
    func loadPost(_ id: PostID) async throws -> FeedEntry {
        throw FeedError.transport(message: "unused")
    }
}
