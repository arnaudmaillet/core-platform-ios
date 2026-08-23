import CoreModels
import CoreNavigation
import FeedInterface
import MediaCore
import PostGrid
import Testing
import UIKit
@testable import Feed

/// THE PRESENTATION A POST WITH NOTHING TO FLY GETS.
///
/// A text-only post has no media surface, so there is no hero at either end of
/// a flight and the honest presentation is a plain push. The defect these tests
/// exist to prevent is what "plain" quietly came to mean on one of the two
/// paths that reach it: a push that inherited the snap feed's claim on its own
/// dismissal (`zoomOwnsInteractiveDismissal` defaults to true, which tells
/// `NativePopPolicy` to refuse the stack's native edge pop) and then attached
/// nothing to honour it. The result renders perfectly and answers no horizontal
/// drag anywhere — a screen whose only way out is the back chevron.
///
/// ⚠️ Every assertion here is about the state left behind by the push, not
/// about pixels, and that is deliberate: the failure is invisible to a
/// screenshot and only a finger — or this — can tell the two apart.
@MainActor
struct PlainPushDismissalTests {

    // MARK: - The defect

    /// The claim and the gesture are ONE act. Asserting only the first would
    /// have passed against the broken build.
    @Test func aPostWithNothingToFlyIsPushedWithADismissalOfItsOwn() {
        let stack = Stack()
        stack.builder.presentSnapFeedHero(
            postIDs: [PostID("t1")], from: stack.presenter, origin: origin(hasHero: false)
        )

        let pushed = try? #require(stack.nav.viewControllers.last)
        #expect(pushed !== stack.presenter, "a post with no hero was not pushed at all")

        // Half one: it still claims the dismissal, because it is about to drive
        // one. This is what makes the second half load-bearing rather than
        // decorative.
        let destination = pushed as? any ZoomTransitionDestination
        #expect(destination?.zoomOwnsInteractiveDismissal == true)
        #expect(
            NativePopPolicy.shouldBegin(
                isAtRoot: false,
                isTransitioning: false,
                hidesBackButton: false,
                ownsInteractiveDismissal: destination?.zoomOwnsInteractiveDismissal,
                hasCustomLeadingItem: true,
                leadingItemsSupplementBackButton: false
            ) == false,
            "the native edge pop is refused — so something else MUST be driving"
        )

        // Half two: and something is. Both the recognizer on the surface and
        // the stack's delegate, since a pan with nobody vending an interaction
        // controller pops instantly instead of following the finger.
        let pans = pushed?.view.gestureRecognizers?.filter { $0 is UIPanGestureRecognizer } ?? []
        #expect(!pans.isEmpty, "claimed the dismissal and attached no gesture to honour it")
        #expect(stack.nav.delegate is InteractiveSlideDismissal,
                "nothing would vend the interaction controller the pan drives")
    }

    /// The dismissal has to outlive the push. It is retained by nothing the
    /// stack holds strongly — a navigation delegate is weak and a gesture
    /// recognizer does not own its target — so a builder that forgot to retain
    /// it would leave a pan whose target is gone, which looks exactly like the
    /// defect above.
    @Test func theDismissalSurvivesTheStackForgettingIt() {
        let stack = Stack()
        stack.builder.presentSnapFeedHero(
            postIDs: [PostID("t1")], from: stack.presenter, origin: origin(hasHero: false)
        )
        let pan = stack.nav.viewControllers.last?.view.gestureRecognizers?
            .compactMap { $0 as? UIPanGestureRecognizer }.first

        #expect(pan?.delegate != nil, "the dismissal was released before the first touch")
        #expect(pan?.delegate === (stack.nav.delegate as? InteractiveSlideDismissal))
    }

    /// The feed owns the whole screen either way it is arrived at.
    @Test func thePlainPushHidesTheTabBar() {
        let stack = Stack()
        #expect(stack.tabs.isTabBarHidden == false, "precondition")

        stack.builder.presentSnapFeedHero(
            postIDs: [PostID("t1")], from: stack.presenter, origin: origin(hasHero: false)
        )

        #expect(stack.tabs.isTabBarHidden, "the bar was left standing over the post")
    }

    /// The opener is showing these posts already, so the destination must not
    /// go dark waiting for its own fetch. Asserted on BOTH presentations: the
    /// flight used to hide the omission by covering the destination with a card
    /// carrying the tile's own pixels.
    @Test(arguments: [true, false])
    func theDestinationArrivesWithItsPageAlreadyRendered(hasHero: Bool) {
        let stack = Stack()
        stack.builder.presentSnapFeedHero(
            postIDs: [PostID("t1")], from: stack.presenter, origin: origin(hasHero: hasHero)
        )

        let destination = stack.nav.viewControllers.last as? any ZoomTransitionDestination
        #expect(destination?.zoomDestinationContentIsReady == true,
                "pushed with nothing to draw until the fetch returns")
    }

    /// An origin that carries no projection still opens — degraded to the slow
    /// hydration, never broken. The seam must not require the seed.
    @Test func anOriginWithNoProjectionStillOpens() {
        let stack = Stack()
        stack.builder.presentSnapFeedHero(
            postIDs: [PostID("t1")],
            from: stack.presenter,
            origin: origin(hasHero: false, stream: [])
        )

        #expect(stack.nav.viewControllers.count == 2)
        #expect(stack.nav.delegate is InteractiveSlideDismissal)
    }

    // MARK: - The control

    /// A post that DOES have media still flies, and the flight still owns the
    /// stack. Without this, "always push plainly" would pass every test above.
    @Test func aPostWithMediaStillFlies() {
        let stack = Stack()
        stack.builder.presentSnapFeedHero(
            postIDs: [PostID("m1")], from: stack.presenter, origin: origin(hasHero: true)
        )

        #expect(stack.nav.delegate is ZoomTransitionController,
                "a flyable post lost its flight")
        #expect(stack.tabs.isTabBarHidden)
    }

    // MARK: - The generic route

    /// The feed reached by `AppRoute.postStream` has no origin to fly from and
    /// no screen-specific object to hang a gesture on, so it must DISCLAIM the
    /// dismissal rather than inherit the claim — otherwise it refuses the only
    /// gesture it has left.
    @Test func aPlainlyBuiltFeedDisclaimsTheDismissalItCannotProvide() {
        let feed = makeBuilder().makeSnapFeedViewController(
            postIDs: [PostID("p1")], ownsInteractiveDismissal: false
        ) as? any ZoomTransitionDestination

        #expect(feed?.zoomOwnsInteractiveDismissal == false)
        #expect(
            NativePopPolicy.shouldBegin(
                isAtRoot: false,
                isTransitioning: false,
                hidesBackButton: false,
                ownsInteractiveDismissal: feed?.zoomOwnsInteractiveDismissal,
                hasCustomLeadingItem: true,
                leadingItemsSupplementBackButton: false
            ),
            "disclaiming has to actually hand the pop back to the platform"
        )
    }

    /// ⚠️ A screen that owns its dismissal DISABLES the stack's edge recognizer
    /// while it is up, rather than relying on the policy refusing it.
    ///
    /// Refusing is not disabling, and the difference is a whole gesture. The
    /// policy already answered "no" for this screen, so the native pop never
    /// popped — but a refused `UIScreenEdgePanGestureRecognizer` is still armed
    /// and takes the touches in the leading strip while it decides, so the
    /// screen's OWN grab was never consulted there. Measured with `-grab-log`: a
    /// drag from x=12 produced no begin decision at all while the same drag at
    /// x=200 produced one — on a post with a carousel and on one without, which
    /// is how the carousel was cleared of a bug it never had.
    ///
    /// Restored on the way out rather than forced back to `true`: the stack's
    /// gesture is not ours, and whatever pushed us may have had its own opinion.
    @Test func aFeedThatOwnsItsDismissalDisablesTheStacksEdgeGesture() {
        let feed = makeBuilder().makeSnapFeedViewController(postIDs: [PostID("p1")])
        let nav = UINavigationController(rootViewController: UIViewController())
        nav.pushViewController(feed, animated: false)
        let pop = nav.interactivePopGestureRecognizer
        pop?.isEnabled = true

        feed.beginAppearanceTransition(true, animated: false)
        feed.endAppearanceTransition()
        #expect(pop?.isEnabled == false)

        feed.beginAppearanceTransition(false, animated: false)
        feed.endAppearanceTransition()
        #expect(pop?.isEnabled == true)
    }

    /// And the unqualified spelling still means what every existing caller
    /// meant by it, so nothing that pairs a flight with this factory silently
    /// starts racing the edge pop.
    @Test func theUnqualifiedFactoryStillClaimsTheDismissal() {
        let feed = makeBuilder().makeSnapFeedViewController(postIDs: [PostID("p1")])
        #expect((feed as? any ZoomTransitionDestination)?.zoomOwnsInteractiveDismissal == true)
    }

    // MARK: - The origin-less caller (Maps text pins)

    /// A caller with NO origin to describe reaches the same presentation with
    /// the same guarantees. This is the seam a Maps text pin uses: it knows post
    /// ids and nothing else, so it cannot fill in a `SnapFeedHeroOrigin`, and
    /// the alternative — its own `pushViewController` — is precisely the
    /// unswipeable screen this suite exists for.
    @Test func anOriginLessPushGetsTheSameDismissal() {
        let stack = Stack()
        stack.builder.pushSnapFeed(postIDs: [PostID("t1")], from: stack.presenter)

        let pushed = try? #require(stack.nav.viewControllers.last)
        #expect(pushed !== stack.presenter, "nothing was pushed")

        // Both halves, exactly as above: the claim AND the gesture honouring it.
        #expect((pushed as? any ZoomTransitionDestination)?.zoomOwnsInteractiveDismissal == true)
        let pans = pushed?.view.gestureRecognizers?.filter { $0 is UIPanGestureRecognizer } ?? []
        #expect(!pans.isEmpty, "claimed the dismissal and attached no gesture to honour it")
        #expect(stack.nav.delegate is InteractiveSlideDismissal,
                "nothing would vend the interaction controller the pan drives")
    }

    /// And it is a PLAIN push: no flight owns the stack, which is the whole
    /// point of the caller choosing this method over `presentSnapFeedHero`.
    @Test func anOriginLessPushDoesNotFly() {
        let stack = Stack()
        stack.builder.pushSnapFeed(postIDs: [PostID("t1")], from: stack.presenter)
        #expect(!(stack.nav.delegate is ZoomTransitionController))
    }

    @Test func anOriginLessPushHidesTheTabBar() {
        let stack = Stack()
        #expect(stack.tabs.isTabBarHidden == false, "precondition")

        stack.builder.pushSnapFeed(postIDs: [PostID("t1")], from: stack.presenter)

        #expect(stack.tabs.isTabBarHidden, "the bar was left standing over the post")
    }

    /// Nothing to open is not a presentation. Asserted because the map's
    /// cluster path can produce an empty id list in principle, and a pushed
    /// feed with no posts is a black screen with a back button.
    @Test func anEmptyPushOpensNothing() {
        let stack = Stack()
        stack.builder.pushSnapFeed(postIDs: [], from: stack.presenter)
        #expect(stack.nav.viewControllers.count == 1)
        #expect(stack.tabs.isTabBarHidden == false, "hid the bar for a screen it never pushed")
    }

    /// A presenter outside any stack cannot be pushed from — and must not take
    /// the tab bar down on its way to doing nothing.
    @Test func aPresenterWithNoStackIsANoOp() {
        let stack = Stack()
        let orphan = UIViewController()
        stack.builder.pushSnapFeed(postIDs: [PostID("t1")], from: orphan)
        #expect(stack.nav.viewControllers.count == 1)
        #expect(stack.tabs.isTabBarHidden == false)
    }

    // MARK: - Fixtures

    /// A navigation stack inside a tab bar controller, inside a window — the
    /// shape `presentSnapFeedHero` actually runs in. Off-window the tab bar
    /// controller answers about a bar it never laid out.
    ///
    /// ⚠️ `@MainActor` on the nested type, not inherited from the suite: a
    /// stored property's DEFAULT VALUE is evaluated in the type's own
    /// isolation, and UIKit initialisers are main-actor bound. Without this the
    /// class does not compile, and the diagnostic names the property rather
    /// than the missing annotation.
    @MainActor
    private final class Stack {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        let presenter = UIViewController()
        let nav: UINavigationController
        let tabs = UITabBarController()
        let builder = makeBuilder()

        init() {
            nav = UINavigationController(rootViewController: presenter)
            tabs.viewControllers = [nav]
            window.rootViewController = tabs
            window.isHidden = false
            window.layoutIfNeeded()
        }
    }

    private static func makeBuilder() -> FeedFeatureBuilder {
        FeedFeatureBuilder(
            repository: SilentProvider(),
            imagePipeline: ImagePipeline(fetcher: PlaceholderImageFetcher())
        )
    }

    private func makeBuilder() -> FeedFeatureBuilder { Self.makeBuilder() }

    private func origin(
        hasHero: Bool,
        stream: [GalleryPost]? = nil
    ) -> SnapFeedHeroOrigin {
        let post = GalleryPost(
            id: PostID(hasHero ? "m1" : "t1"),
            kind: hasHero ? .photo : .text,
            isRepost: false,
            thumbnailURL: nil,
            caption: "a caption",
            publishedAtMS: 0
        )
        return SnapFeedHeroOrigin(
            post: post,
            stream: stream ?? [post],
            hasHero: hasHero,
            cover: nil,
            style: .listMedia,
            // A rect is offered regardless: the point of `hasHero` is that it is
            // NOT derivable from this closure, which answers the transient
            // "still on screen?" question rather than the permanent one.
            frame: { _ in CGRect(x: 0, y: 0, width: 100, height: 100) },
            isOnScreen: { true },
            setConcealed: { _ in }
        )
    }
}

/// Answers nothing, slowly — so anything the destination renders came from the
/// projection rather than from a fetch that happened to be instant.
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
