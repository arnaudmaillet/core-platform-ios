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

    // MARK: - 2.16 A feed leaving with its flight hands the bars' style back

    /// A push caught and thrown back never reaches the feed's
    /// `viewWillDisappear`, which is where the shared bars' style was handed
    /// back — the presenter's header stayed in the feed's dark style. The
    /// flight's own "you are departing" now hands it back.
    @Test func aFeedDepartingWithItsFlightHandsTheBarsStyleBack() {
        let feed = Self.feed()
        let nav = UINavigationController(rootViewController: UIViewController())
        nav.pushViewController(feed, animated: false)
        nav.navigationBar.overrideUserInterfaceStyle = .dark   // lent for the visit
        nav.toolbar.overrideUserInterfaceStyle = .dark

        feed.zoomTransitionWillDepart()
        feed.zoomTransitionDidEnd()

        #expect(nav.navigationBar.overrideUserInterfaceStyle == .unspecified,
                "the presenter's header kept the feed's style")
        #expect(nav.toolbar.overrideUserInterfaceStyle == .unspecified)
    }

    // MARK: - A grab keeps the bottom bar's style until it is decided (#1315)

    /// ⚠️ THE BOTTOM BAR STAYS ON SCREEN THROUGH A GRAB: handed back at its
    /// first frame, it turned light over the media page for the whole grab
    /// and after a cancel (filmed by the owner, 2026-10-17). Neither bar is
    /// handed back before a commit (#1325).
    @Test(arguments: [true, false])
    func aGrabKeepsTheToolbarsStyleUntilItIsDecided(commits: Bool) {
        let feed = Self.feed()
        let nav = UINavigationController(rootViewController: UIViewController())
        nav.pushViewController(feed, animated: false)
        nav.navigationBar.overrideUserInterfaceStyle = .dark   // lent for the visit
        nav.toolbar.overrideUserInterfaceStyle = .dark

        var decide: ((Bool) -> Void)?
        feed.handBackChromeTheme(interactive: true) { decide = $0 }
        // Both bars, the header too (#1325): it turned light over the media
        // page for the whole grab when it was handed back at the first frame.
        #expect(nav.navigationBar.overrideUserInterfaceStyle == .dark, "the header went light mid-grab")
        #expect(nav.toolbar.overrideUserInterfaceStyle == .dark, "the bottom bar went light mid-grab")

        decide?(commits)
        #expect(nav.toolbar.overrideUserInterfaceStyle == (commits ? .unspecified : .dark))
        #expect(nav.navigationBar.overrideUserInterfaceStyle == (commits ? .unspecified : .dark))
    }

    /// ⚠️ THE RELEASE DECIDES, THE COMPLETION ONLY BACKS IT UP (#1510): the
    /// bars switched at the landing when the completion decided. The first
    /// report wins; a release never reported leaves it to the completion.
    @Test(arguments: [true, false])
    func theFirstReportDecidesAGrab(commits: Bool) {
        var outcomes: [Bool] = []
        let released = SnapFeedViewController.GrabDecision { outcomes.append($0) }
        released.report(committed: commits)      // the release
        released.report(committed: commits)      // the completion
        #expect(outcomes == [commits], "a grab was decided twice, or not at the release")

        outcomes = []
        let unreleased = SnapFeedViewController.GrabDecision { outcomes.append($0) }
        unreleased.report(committed: commits)    // the completion alone
        #expect(outcomes == [commits], "the completion no longer backs a grab with no release")
    }

    /// An ordinary disappearance hands everything back at once.
    @Test func aPlainDisappearanceHandsTheToolbarBackAtOnce() {
        let feed = Self.feed()
        let nav = UINavigationController(rootViewController: UIViewController())
        nav.pushViewController(feed, animated: false)
        nav.toolbar.overrideUserInterfaceStyle = .dark
        feed.handBackChromeTheme(interactive: false) { _ in }
        #expect(nav.toolbar.overrideUserInterfaceStyle == .unspecified)
    }

    // MARK: - A media page arrives under dark bars

    /// ⚠️ A FEED PUSHED FRESH WITH A SEED (a For You rail card's hero) has no
    /// active page before its first layout; its bars flew in LIGHT over a
    /// media post (the owner, on a device, 2026-10-15). The arriving page is
    /// the seed's: a media one themes the bars dark at appearance, a text
    /// one leaves them the page's.
    @Test(arguments: [true, false])
    func aSeededPageThemesTheBarsAtItsArrival(media: Bool) {
        let feed = Self.feed()
        let model = SnapActionColumnLayoutTests.mediaModel(mediaURL: media ? URL(string: "mock://media/1") : nil)
        feed.seedProjection([model])
        #expect(feed.arrivalModel?.id == model.id, "the arriving page is not the seed's")

        // In the stack, then appearing BEFORE any layout — the moment the
        // flight starts, when no page is active yet.
        let stack = Stack()
        stack.nav.setViewControllers([stack.presenter, feed], animated: false)
        feed.beginAppearanceTransition(true, animated: true)
        defer { feed.endAppearanceTransition() }
        let expected: UIUserInterfaceStyle = media ? .dark : .unspecified
        #expect(stack.nav.toolbar.overrideUserInterfaceStyle == expected, "the toolbar arrived in the wrong style")
        #expect(stack.nav.navigationBar.overrideUserInterfaceStyle == expected)
    }

    // MARK: - A grab decided after the pop hands the bars back (#1500)

    /// ⚠️ A COMMITTED GRAB REPORTS FROM THE TRANSITION'S COMPLETION, AFTER
    /// THE POP: the feed is off the stack and has no `navigationController`.
    /// The release found no bars, and the presenter's header stayed dark after
    /// a rightward grab (filmed by the owner, 2026-10-21). A cancelled grab
    /// keeps the dark bars: the post is still on screen.
    @Test(arguments: [true, false])
    func aGrabDecidedAfterThePopHandsTheBarsBack(commits: Bool) {
        let feed = Self.feed()
        feed.seedProjection([SnapActionColumnLayoutTests.mediaModel(mediaURL: URL(string: "mock://media/1"))])
        let stack = Stack()
        stack.nav.setViewControllers([stack.presenter, feed], animated: false)
        // The stack's own appearance of the feed, done before the grab.
        stack.window.layoutIfNeeded()
        #expect(stack.nav.navigationBar.overrideUserInterfaceStyle == .dark, "the media page lent no style")

        var decide: ((Bool) -> Void)?
        feed.handBackChromeTheme(interactive: true) { decide = $0 }
        #expect(stack.nav.navigationBar.overrideUserInterfaceStyle == .dark, "the header went light mid-grab")
        if commits {
            // UIKit has popped the feed by the time the completion reports.
            stack.nav.setViewControllers([stack.presenter], animated: false)
            #expect(feed.navigationController == nil)
        }
        decide?(commits)
        let expected: UIUserInterfaceStyle = commits ? .unspecified : .dark
        #expect(stack.nav.navigationBar.overrideUserInterfaceStyle == expected, "the presenter's header kept the post's style")
        #expect(stack.nav.toolbar.overrideUserInterfaceStyle == expected)
    }

    /// Once handed back, a late callback lends nothing (#1500): an appearance
    /// callback, a page settling or the author pill re-hosted after the
    /// release re-styled the presenter's bars, with nothing to hand them back.
    @Test func nothingLendsTheBarsAfterTheHandBack() {
        let feed = Self.feed()
        feed.seedProjection([SnapActionColumnLayoutTests.mediaModel(mediaURL: URL(string: "mock://media/1"))])
        let stack = Stack()
        stack.nav.setViewControllers([stack.presenter, feed], animated: false)
        // The stack's own appearance of the feed, done before the hand-back.
        stack.window.layoutIfNeeded()
        #expect(stack.nav.navigationBar.overrideUserInterfaceStyle == .dark, "the media page lent no style")
        feed.handBackChromeTheme(interactive: false) { _ in }
        #expect(stack.nav.navigationBar.overrideUserInterfaceStyle == .unspecified)

        // A late "did appear" — the re-apply paths' shape.
        feed.viewDidAppear(false)
        #expect(stack.nav.navigationBar.overrideUserInterfaceStyle == .unspecified, "a late callback re-lent the style")
        #expect(stack.nav.toolbar.overrideUserInterfaceStyle == .unspecified)

        // Appearing again lends it again.
        feed.beginAppearanceTransition(true, animated: false)
        feed.endAppearanceTransition()
        #expect(stack.nav.navigationBar.overrideUserInterfaceStyle == .dark, "a return lent no style")
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
