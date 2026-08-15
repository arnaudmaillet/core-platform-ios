import MediaCore
import CoreModels
import CoreStorage
import ProfileInterface
import CoreNavigation
import FeedInterface
import MediaPlayback
import PostGrid
import UIKit

/// The feed feature's entry point, resolved by the composition root and
/// consumed through `FeedFeatureBuilding` by the app shell.
@MainActor
public struct FeedFeatureBuilder: FeedFeatureBuilding {
    private let repository: any FeedProviding
    private let engagementProvider: (any EngagementProviding)?
    private let commentsProvider: (any CommentsProviding)?
    private let realtime: (any FeedRealtimeSubscribing)?
    private let composedPosts: ComposedPostChannel?
    private let router: (any Router)?
    private let imagePipeline: ImagePipeline
    private let videoPlayback: VideoPlaybackController?
    /// Vends the profile switcher for the comments composer's avatar menu.
    ///
    /// A FACTORY, not an instance: `ProfileSwitcherPresenting` caches its
    /// pre-formatted rows from the last `reload()`, so each surface that
    /// offers switching holds its own — sharing one would make two screens
    /// race over the same row cache. Nil leaves the composer's face inert.
    private let makeProfileSwitcher: (@MainActor () -> (any ProfileSwitcherPresenting)?)?
    /// The viewer's point balance, shared with every surface that shows or
    /// spends it (the map toolbar's badge, the rail's boost anchor, the
    /// comments bar). One instance app-wide — `WalletStore`'s change post is
    /// scoped to the instance. Nil leaves the boost buttons inert.
    private let wallet: WalletStore?
    /// Vends the wallet/claim sheet for the feed header's balance badge —
    /// injected because the sheet is shell-owned (it is the same one the
    /// map's badge presents, and the two must never diverge). Nil leaves
    /// the feed's badge display-only, the pre-sheet behaviour.
    private let makeWalletSheet: (@MainActor () -> UIViewController)?

    public init(
        repository: any FeedProviding,
        engagementProvider: (any EngagementProviding)? = nil,
        commentsProvider: (any CommentsProviding)? = nil,
        realtime: (any FeedRealtimeSubscribing)? = nil,
        composedPosts: ComposedPostChannel? = nil,
        router: (any Router)? = nil,
        imagePipeline: ImagePipeline,
        videoPlayback: VideoPlaybackController? = nil,
        makeProfileSwitcher: (@MainActor () -> (any ProfileSwitcherPresenting)?)? = nil,
        wallet: WalletStore? = nil,
        makeWalletSheet: (@MainActor () -> UIViewController)? = nil
    ) {
        self.makeProfileSwitcher = makeProfileSwitcher
        self.repository = repository
        self.engagementProvider = engagementProvider
        self.commentsProvider = commentsProvider
        self.realtime = realtime
        self.composedPosts = composedPosts
        self.router = router
        self.imagePipeline = imagePipeline
        self.videoPlayback = videoPlayback
        self.wallet = wallet
        self.makeWalletSheet = makeWalletSheet
    }

    /// The timeline is the full-screen snap feed — the app's sole Timeline.
    public func makeFeedViewController() -> UIViewController {
        makeSnapFeed(
            viewModel: FeedViewModel(
                repository: repository,
                engagementProvider: engagementProvider,
                commentsProvider: commentsProvider,
                realtime: realtime,
                composedPosts: composedPosts,
                router: router
            )
        )
    }

    public func prewarmPosts(_ ids: [PostID]) async {
        await repository.prewarm(ids)
    }

    public func makeForYouViewController(
        onTabPresentationChange: ((ForYouTabPresentation) -> Void)?
    ) -> UIViewController {
        let repository = repository
        let forYou = ForYouViewController(
            viewModel: ForYouViewModel(
                repository: ForYouRepository(feed: repository),
                // Its OWN namespace. The profile gallery persists the same
                // format axis under `profile.gallery.*`; sharing the keys would
                // make each surface yank the other's landing tab.
                preferences: GalleryPreferences(keyPrefix: "foryou.gallery"),
                contextStore: ContentContextStore()
            ),
            imagePipeline: imagePipeline,
            // Deliberately the SAME pool the snap feed uses. The grid parks a
            // tile's running player for the feed to adopt, and a park in one
            // pool is invisible to another — two pools would silently restart
            // every video at 0:00 on tap.
            videoPlayback: videoPlayback,
            // The same seeded surface a Maps pin opens, from a tile instead.
            makeSnapFeed: { postIDs in makeSnapFeedViewController(postIDs: postIDs) },
            prewarm: { ids in await repository.prewarm(ids) },
            // Text posts open straight into comment layout, so their first
            // page is warmed while the grid is still on screen — see
            // `prewarmVisible`.
            prefetchTopComments: { [commentsProvider] id in
                await commentsProvider?.prefetchTopComments(for: id)
            },
            // For the `+` item, which routes to the composer rather than
            // building one.
            router: router
        )
        forYou.onTabPresentationChange = onTabPresentationChange
        return forYou
    }

    public func presentSnapFeedHero(
        postIDs: [PostID],
        from presenter: UIViewController,
        origin: SnapFeedHeroOrigin
    ) {
        guard !postIDs.isEmpty, let nav = presenter.navigationController else { return }
        let destination = makeSnapFeedViewController(postIDs: postIDs)
        // Hand over the projection the origin is already showing, on BOTH
        // presentations. The flight used to hide the cost of not doing this —
        // the card carries the tile's own pixels, so the destination behind it
        // could be empty for the length of the animation and nobody saw it —
        // which is why this was only ever noticed on the plain push below.
        (destination as? SnapFeedViewController)
            .map { $0.seedProjection(GalleryPostProjection.seedModels(from: origin.stream)) }
        // The snap feed is the only thing this builds, and it conforms — but
        // the factory is typed `UIViewController` for callers who do not care.
        //
        // ⚠️ `hasHero` is asked FIRST, and it is not the same question as
        // whether the cast succeeds. A text-only post has no media surface at
        // either end of a flight, so there is nothing to fly even though the
        // destination is perfectly flyable. Both answers land on the same feed;
        // only the way in differs, which is the right thing to degrade.
        //
        // Historically this method had no such branch: an origin with no hero
        // was flown anyway (from a rect it had to invent), and a destination
        // that failed the cast was silently dropped on the floor — the tap did
        // nothing at all. Neither is a presentation.
        guard origin.hasHero, let flyable = destination as? any ZoomTransitionDestination else {
            pushWithoutFlight(destination, on: nav)
            return
        }
        let source = ExternalHeroZoomSource(origin: origin)
        let transition = ZoomTransitionController(source: source, destination: flyable)
        // The pushed feed owns its dismissal grab, exactly as it does when the
        // For You grid opens it — otherwise the stack's edge gesture and the
        // flight's own grab both try to drive one pop.
        (destination as? SnapFeedViewController)?.zoomOwnsInteractiveDismissal = true

        // This builder is a struct, so it cannot hold the transition alive.
        // The retainer does, and the transition retains the closure that holds
        // the retainer — a cycle that lasts exactly as long as the flight and
        // is broken by the return leg. The alternative was an associated object
        // on the presenter, which hides the lifetime rather than stating it.
        let retainer = HeroTransitionRetainer()
        retainer.transition = transition
        // SAVED, not assumed nil. The presenter may already own the stack's
        // delegate — a profile installs an `InteractiveSlideDismissal` as one
        // before it pushes anything — and restoring nil orphaned it: the
        // object still believed it was installed, its pan still began and
        // called `popViewController`, but with no delegate UIKit never asked
        // for the interaction controller. The pop ran instantly instead of
        // following the finger, and every grab above it stayed broken because
        // nothing ever put the delegate back.
        let previousDelegate = nav.delegate
        transition.onSourceReturned = { [weak nav, weak previousDelegate] in
            nav?.delegate = previousDelegate
            origin.setConcealed(false)
            retainer.transition = nil
            Self.restoreTabBar(on: nav)
        }
        // THE GRAB. Without it this push had no dismissal gesture at all:
        // claiming `zoomOwnsInteractiveDismissal` above tells the stack's
        // native edge-swipe to stay out of the way, which is correct only
        // because the flight attaches its own — and a claim with nothing
        // behind it leaves the screen unswipeable. Accessing `view` loads it
        // so the pan has something to attach to.
        transition.attachInteractiveDismissal(to: destination.view) { [weak nav] in
            nav?.popViewController(animated: true)
        }
        #if DEBUG
        // `-zoom-live-log`: the grab is invisible until a finger arrives, and
        // the simulator has none — so this is the only way a scripted run can
        // tell "attached" from "claimed ownership and attached nothing", which
        // is what left profile-opened posts unswipeable.
        if ProcessInfo.processInfo.arguments.contains("-zoom-live-log") {
            let pans = destination.view.gestureRecognizers?
                .filter { $0 is UIPanGestureRecognizer }.count ?? 0
            print("[hero] pushed with dismissal grab: pans=\(pans)")
        }
        #endif
        #if DEBUG
        // `-hero-demo-grab`: dismiss the pushed post by grab once it lands, so a
        // scripted run can see the surface UNDERNEATH in its returned state.
        // The reveal that runs while the post covers it is only observable there.
        if ProcessInfo.processInfo.arguments.contains("-hero-demo-grab") {
            transition.onDestinationShown = { [weak transition] in
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    transition?.debugScriptedGrab()
                }
            }
        }
        #endif
        // ⚠️ Hidden BY HAND, not with `hidesBottomBarWhenPushed`.
        //
        // The feed reached for that flag twice and measured the same defect both
        // times — most recently on the plain percent driver this path also uses:
        // its bottom-bar choreography does not scrub with a custom interactive
        // pop, so the bar arrives fully rendered at pop-begin and stands over the
        // post for the whole length of a grab. See `FeedFlowCoordinator.push`,
        // which hides on the push and restores on the completed pop; this is the
        // same cure for the same push, arriving from a profile instead of a pin.
        //
        // Nothing else was hiding it here: `syncTabBarVisibility` runs on tab
        // selection, never on a push, and this push replaces the navigation
        // delegate with the flight — so the shell hears nothing either.
        #if DEBUG
        // `-tabbar-flag`: the A/B this decision rests on. Swaps the hand-managed
        // hide for `hidesBottomBarWhenPushed`, so the two can be filmed against
        // each other on the same grab rather than argued about.
        if ProcessInfo.processInfo.arguments.contains("-tabbar-flag") {
            destination.hidesBottomBarWhenPushed = true
        } else {
            nav.tabBarController?.setTabBarHidden(true, animated: true)
        }
        #else
        nav.tabBarController?.setTabBarHidden(true, animated: true)
        #endif
        transition.onPresentationCancelled = { [weak nav] in Self.restoreTabBar(on: nav) }
        nav.delegate = transition
        nav.pushViewController(destination, animated: true)
    }

    public func makeClusterGallery(
        postIDs: [PostID],
        title: String,
        feed: UIViewController
    ) -> UIViewController {
        let base = repository
        let gallery = ClusterGalleryViewController(
            postIDs: postIDs,
            imagePipeline: imagePipeline,
            videoPlayback: videoPlayback,
            loadPosts: {
                // One hydration over the same provider shape the feed above
                // uses, so every member is a cache hit; ranked client-side
                // because no ranking RPC exists (BACKEND_GAPS §14/§18).
                let provider = FixedPostsFeedProvider(base: base, ids: postIDs)
                let members = try await ForYouRepository(feed: provider).firstPage().posts
                return DiscoverySource.trending.ordering(members)
            },
            openPost: { presenter, origin, ids in
                presentSnapFeedHero(postIDs: ids, from: presenter, origin: origin)
            }
        )
        gallery.title = title
        gallery.activePostID = { [weak feed] in
            (feed as? SnapFeedViewController)?.activePostID
        }
        // Eager on purpose: the gallery lives its early life invisible under
        // the feed (a mid-stack insertion never loads its view), and the
        // first anyone sees of it is a dismissal LANDING on it.
        gallery.beginLoading()
        return gallery
    }

    /// The plain push, for a caller with no origin to describe.
    ///
    /// `presentSnapFeedHero` reaches the same place when its origin reports
    /// `hasHero == false`, and that is the right shape for a surface that HAS
    /// an origin (a grid tile knows its post, its pixels and its rect). A Maps
    /// text pin has none of that — a symbol on a circle is not a cover, and the
    /// pin carries ids rather than models — so it says so directly instead of
    /// filling a hero origin with fields the plain branch never reads.
    ///
    /// One line of body, and it is the point: everything that makes this push
    /// survivable (the dismissal, its retainer, the tab bar) is in
    /// `pushWithoutFlight`, and a second surface reaching for a bare
    /// `pushViewController` is exactly the regression `PlainPushDismissalTests`
    /// guards.
    public func pushSnapFeed(postIDs: [PostID], from presenter: UIViewController) {
        guard !postIDs.isEmpty, let nav = presenter.navigationController else { return }
        pushWithoutFlight(makeSnapFeedViewController(postIDs: postIDs), on: nav)
    }

    /// Pushes the feed with no flight, and gives it a way back by hand.
    ///
    /// The presentation a post with nothing to fly gets: a native push, plus a
    /// full-surface rightward swipe that scrubs the pop 1:1 and releases on the
    /// same contract every other dismissal in this app uses. Deliberately the
    /// SAME shape as `ForYouViewController`'s text branch, because a viewer
    /// opening the same text post from a profile and from For You is looking at
    /// one screen and must get one set of gestures.
    ///
    /// ⚠️ Claiming ownership and attaching the swipe are ONE act, never two.
    /// `zoomOwnsInteractiveDismissal` tells `NativePopPolicy` to refuse the
    /// stack's native edge pop — correct only because something else is about
    /// to drive the dismissal. The whole defect this method exists to fix was a
    /// push that inherited the claim (it is the type's default) and attached
    /// nothing: a screen that refused every horizontal drag, edge or surface,
    /// leaving the back chevron as the only way out.
    private func pushWithoutFlight(_ destination: UIViewController, on nav: UINavigationController) {
        (destination as? SnapFeedViewController)?.zoomOwnsInteractiveDismissal = true

        // This builder is a struct and `UINavigationController.delegate` is
        // weak, so nothing here would otherwise keep the dismissal alive to see
        // the swipe. The retainer does; the dismissal's own completion clears
        // it, so the cycle lasts exactly as long as the screen does — the same
        // bargain `HeroTransitionRetainer` strikes for the flight.
        let retainer = SlideDismissalRetainer()
        let dismissal = InteractiveSlideDismissal()
        retainer.dismissal = dismissal
        // Accessing `view` loads it so the pan has something to attach to.
        dismissal.attach(to: destination, axes: [.horizontal, .vertical])
        dismissal.onFeedPopped = { nav in
            // Completed pops only — swipe or back button. A cancelled swipe
            // reports nothing here, which is exactly right: the feed is staying
            // up and the bar must stay down.
            Self.restoreTabBar(on: nav)
            retainer.dismissal = nil
        }
        // SAVED, not clobbered — `install` captures whatever owned the stack
        // before this screen and hands it back on teardown. A pushed profile
        // owns it (its own `InteractiveSlideDismissal` for the profile's
        // dismissal), and that has to survive this push intact.
        dismissal.install(on: nav)

        // Hidden BY HAND for the same reason the flight path states at length:
        // `hidesBottomBarWhenPushed`'s choreography does not scrub with a custom
        // interactive pop, and this screen now has one.
        nav.tabBarController?.setTabBarHidden(true, animated: true)
        nav.pushViewController(destination, animated: true)
        #if DEBUG
        // `-zoom-live-log`: the only way a scripted run can tell "attached" from
        // "claimed ownership and attached nothing", which is what the defect
        // looked like from the outside — a screen that renders perfectly and
        // answers no gesture.
        if ProcessInfo.processInfo.arguments.contains("-zoom-live-log") {
            let pans = destination.view.gestureRecognizers?
                .filter { $0 is UIPanGestureRecognizer }.count ?? 0
            print("[hero] pushed WITHOUT flight, dismissal pans=\(pans)")
        }
        // `-text-swipe-demo <peak>`: walks the exact begin/update/release path a
        // finger drives, since the simulator injects none. The SAME argument
        // For You's own text branch honours, deliberately — a viewer's thumb
        // does not know which screen opened the post, so neither should the
        // harness that stands in for it.
        //
        // ⚠️ It reports whether the pop is being DRIVEN, not whether the screen
        // went away. With no delegate — or one that does not vend this driver —
        // `popViewController` still pops on UIKit's own animation: the depth
        // changes, the screen leaves, and a harness watching only for that
        // reports success while a real finger would have watched the page jump
        // instead of follow. That distinction is the entire defect.
        let arguments = ProcessInfo.processInfo.arguments
        if let position = arguments.firstIndex(of: "-text-swipe-demo"),
           position + 1 < arguments.count,
           let peak = Double(arguments[position + 1]) {
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                let driven = await dismissal.debugPerformSwipe(peakProgress: CGFloat(peak))
                print("[text-swipe] peak=\(peak) driven=\(driven)")
            }
        }
        #endif
    }

    /// Brings the dock back after a flight that hid it.
    ///
    /// ⚠️ Called from EVERY close-out, not just the completed return. A flight
    /// ends three ways and only one is `onSourceReturned`: the push can be caught
    /// and reversed mid-air (`onPresentationCancelled`, where the destination
    /// never showed), and the grab can be released short of the threshold
    /// (`onDismissalCancelled`, where it stays up and the bar must stay down).
    /// Hanging the restore on one of the three is how a viewer ends up on their
    /// profile with no dock and no gesture that brings it back.
    ///
    /// A local closure was the first shape of this and it CRASHED the Swift
    /// frontend — captured into the flight's own callbacks, it segfaulted the
    /// compiler rather than failing to typecheck. A method is not a workaround
    /// here; it is the thing that compiles.
    private static func restoreTabBar(on nav: UINavigationController?) {
        guard let nav, !(nav.topViewController is any ZoomTransitionDestination) else { return }
        nav.tabBarController?.tabBar.alpha = 1
        // Idempotent, because the screen underneath may have got there first:
        // a tab ROOT asserts its own dock on the far side of a committed scrub
        // (`ProfileViewController.revealDock`), and the two orders are not
        // guaranteed. Whichever arrives first animates; the second finds the bar
        // already down and does nothing.
        guard nav.tabBarController?.isTabBarHidden == true else { return }
        nav.tabBarController?.setTabBarHidden(false, animated: true)
    }

    public func makeSnapFeedViewController(
        postIDs: [PostID],
        ownsInteractiveDismissal: Bool
    ) -> UIViewController {
        let feed = makeSnapFeed(
            viewModel: FeedViewModel(
                repository: FixedPostsFeedProvider(base: repository, ids: postIDs),
                engagementProvider: engagementProvider,
                commentsProvider: commentsProvider,
                router: router
            )
        )
        (feed as? SnapFeedViewController)?.zoomOwnsInteractiveDismissal = ownsInteractiveDismissal
        // Seed the projection the way For You's hero push does — and for
        // the same measured symptom: the push begins in the SAME runloop
        // turn this factory returns in, and the nav bar lays its incoming
        // chrome out at that instant. For You's bar arrives fully formed
        // because its grid seeds synchronously; a pin-opened feed used to
        // fill in from a fetch (then from an awaited cache read — still one
        // hop too late), so its header visibly re-laid itself INSIDE the
        // animation. `peekPost` is the synchronous read of the same warmed
        // cache: everything it can answer is seeded before the push exists.
        // Additive like every seed: a real render replaces it, a seed
        // landing after one is ignored.
        if let snapFeed = feed as? SnapFeedViewController {
            let cached = postIDs.compactMap { repository.peekPost($0) }
            if cached.count == postIDs.count, !cached.isEmpty {
                // ALL answered — the normal pin case, since pins prewarm on
                // viewport settle.
                snapFeed.seedProjection(
                    FeedDisplayModelBuilder().build(cached, relativeTo: Date())
                )
            } else {
                // A partial synchronous seed would TRUNCATE the corpus (a
                // second seed is ignored by contract), so a cold or
                // half-warm set takes the whole async path — late, but no
                // later than the old behaviour.
                let repository = repository
                Task { @MainActor [weak snapFeed] in
                    var entries: [FeedEntry] = []
                    for id in postIDs {
                        guard let entry = try? await repository.loadPost(id) else { continue }
                        entries.append(entry)
                    }
                    guard !entries.isEmpty else { return }
                    snapFeed?.seedProjection(
                        FeedDisplayModelBuilder().build(entries, relativeTo: Date())
                    )
                }
            }
        }
        return feed
    }

    /// The single construction truth for BOTH feed surfaces — the timeline
    /// pushed from the bar's Feed button and the pin-opened contextual feed.
    /// They must stay visually and behaviorally identical; the only sanctioned
    /// difference is the view model's data scope (full timeline vs. the pin's
    /// posts, plus the live channels only an open-ended timeline consumes).
    /// Add screen configuration here, never in one caller.
    private func makeSnapFeed(viewModel: FeedViewModel) -> UIViewController {
        let repository = repository
        let engagementProvider = engagementProvider
        let commentsProvider = commentsProvider
        let router = router
        let imagePipeline = imagePipeline
        // Hoisted like the rest: the panel factory escapes, and reaching for
        // a stored property inside it would capture the whole builder.
        let makeProfileSwitcher = makeProfileSwitcher
        let wallet = wallet
        let makeWalletSheet = makeWalletSheet
        return SnapFeedViewController(
            viewModel: viewModel,
            imagePipeline: imagePipeline,
            videoPlayback: videoPlayback,
            // The comments panel embeds the same comments-only detail the
            // `.comments` route pushes — one comments UI, two presentations.
            // Text-only pages host the SAME panel (their engaged card
            // carries the post, exactly like media pages).
            makeCommentsPanelContent: { postID in
                PostDetailViewController(
                    viewModel: PostDetailViewModel(
                        postID: postID,
                        repository: repository,
                        engagementProvider: engagementProvider,
                        commentsProvider: commentsProvider,
                        router: router
                    ),
                    imagePipeline: imagePipeline,
                    mode: .commentsOnly,
                    profileSwitcher: makeProfileSwitcher?(),
                    wallet: wallet
                )
            },
            wallet: wallet,
            makeWalletSheet: makeWalletSheet
        )
    }

    public func makePostDetailViewController(for postID: PostID, mode: PostDetailMode) -> UIViewController {
        PostDetailViewController(
            viewModel: PostDetailViewModel(
                postID: postID,
                repository: repository,
                engagementProvider: engagementProvider,
                commentsProvider: commentsProvider,
                router: router
            ),
            imagePipeline: imagePipeline,
            mode: mode,
            wallet: wallet
        )
    }
}

/// Keeps a hero transition alive for the length of its flight.
///
/// `FeedFeatureBuilder` is a value type and a navigation controller's delegate
/// is weak, so without this the transition would be released before the card
/// left the ground.
@MainActor
final class HeroTransitionRetainer {
    var transition: ZoomTransitionController?
}

/// Keeps a plain push's swipe-to-dismiss alive for the length of the screen.
///
/// Same reason as above, different object: a navigation controller's delegate
/// is weak, a gesture recognizer does not retain its target, and the builder
/// that wires both is a value type. Without this the dismissal would be gone
/// before the first touch — which looks identical to never having attached one.
@MainActor
final class SlideDismissalRetainer {
    var dismissal: InteractiveSlideDismissal?
}
