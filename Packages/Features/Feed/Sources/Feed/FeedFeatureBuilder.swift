import MediaCore
import CoreContracts
import CoreModels
import CoreNetworking
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
    /// Files moderation reports raised from a post card's "..." menu. Nil
    /// withholds the Report row.
    private let reporting: (any ContentReporting)?
    /// Unfollows an author from that same menu. Nil withholds the Unfollow row.
    ///
    /// Both are the general seams from `CoreModels`, not this feature's own:
    /// the concrete implementations live where the moderation and social-graph
    /// clients are already wired, and the composition root hands the same
    /// instances to whoever needs them.
    private let socialGraph: (any SocialGraphWriting)?

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
        makeWalletSheet: (@MainActor () -> UIViewController)? = nil,
        reporting: (any ContentReporting)? = nil,
        socialGraph: (any SocialGraphWriting)? = nil,
        /// Reads the numbers the timeline does not carry, so a card can show
        /// reach. Optional: without it the cards simply hide their counter,
        /// which is what they did before.
        counterClient: (any Counter_V1_CounterServiceClientInterface)? = nil
    ) {
        self.counterClient = counterClient
        self.reporting = reporting
        self.socialGraph = socialGraph
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
        #if DEBUG
        // See `isColdOpenForced`: a warmed corpus seeds synchronously and the
        // cold path is unreachable, which is why it could only be filmed by
        // accident on a slow machine.
        guard !Self.isColdOpenForced else { return }
        #endif
        await repository.prewarm(ids)
    }

    #if DEBUG
    /// `-feed-cold-open [ms]`: forces the path a FIRST open takes, and holds it
    /// open long enough to film.
    ///
    /// ⚠️ THE COLD PATH IS NORMALLY UNREACHABLE ON DEMAND, and that is the
    /// point of this. `prewarmVisiblePosts` warms up to 16 posts on every
    /// viewport settle, seconds before any tap, and the seed below is
    /// all-or-nothing — so whether a given pin opens cold depends on a Set's
    /// iteration order and on which sweep was cancelled by the next. A defect
    /// reachable only by luck is a defect nobody can prove fixed.
    ///
    /// It suppresses the prewarm, forbids the synchronous seed, and delays the
    /// hydration by `ms` (default 800). The delay sits on the POST fetch alone,
    /// not the transport, so the map's own markers stay fast and the window
    /// under test is the only slow thing.
    static var isColdOpenForced: Bool {
        ProcessInfo.processInfo.arguments.contains("-feed-cold-open")
    }
    #endif

    private let counterClient: (any Counter_V1_CounterServiceClientInterface)?

    public func makeForYouViewController(
        onTabPresentationChange: ((ForYouTabPresentation) -> Void)?
    ) -> UIViewController {
        let repository = repository
        let forYou = ForYouViewController(
            viewModel: ForYouViewModel(
                repository: ForYouRepository(feed: repository, counterClient: counterClient),
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
            router: router,
            // For a row's "...". Both are optional and both gate their own menu
            // row, so a composition root that supplies neither gets a grid with
            // no overflow control rather than one that offers dead actions.
            reporting: reporting,
            socialGraph: socialGraph
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
        // ⚠️ OPENED BY ITS COMMENT COUNT — the thread comes up with the page.
        //
        // Handed over as a page instruction rather than acted on at the tap, so
        // the destination spends the engagement's layout when it is ready to.
        // The reveal point is the rect the flight is about to fly, so the
        // thread is revealed OUT of the photograph rather than arriving over
        // it. Same shape as For You's own chip.
        if origin.opensComments {
            (destination as? SnapFeedViewController)?.openComments(
                for: origin.post.id, revealingFrom: origin.frame(presenter.view)
            )
        }
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
            pushWithoutFlight(destination, on: nav, reveal: origin.textReveal)
            return
        }
        // The feed is a pager and this origin lands where it took off, so the
        // one thing the source cannot work out for itself is what the viewer is
        // leaving — asked of the feed, at staging, never captured here.
        let source = ExternalHeroZoomSource(
            origin: origin,
            settle: { [weak destination] in
                let feed = destination as? any SnapFeedSettleReporting
                return (id: feed?.settledPostID, cover: feed?.settledCoverImage)
            }
        )
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
        // ⚠️ BOTH AXES GO HOME TO THE TILE, including for a post opened from
        // the PLACE PAGE.
        //
        // That page used to split them: the vertical grab flew home while the
        // horizontal one ESCAPED past the gallery to the map, on the reading
        // that a rightward swipe is the platform's back gesture and the map is
        // where the flow began. It read as a level being skipped. A post opened
        // from a place belongs to that place, so both ways out of it land
        // there, and leaving the place for the map is the place's own gesture
        // to offer (`installMapReturnIfTop`) — one screen, one level, each
        // time.
        //
        // What went with the split: the escape's slide, the stack surgery that
        // dropped the gallery mid-gesture and re-inserted it on a cancel, and
        // the `setDismissSource` registration that pointed a pop at a marker.
        // A gesture that no longer crosses two levels needs none of it.
        let galleryPresenter = presenter as? PlaceProfileViewController
        // THE GRAB. Without it this push had no dismissal gesture at all:
        // claiming `zoomOwnsInteractiveDismissal` above tells the stack's
        // native edge-swipe to stay out of the way, which is correct only
        // because the flight attaches its own — and a claim with nothing
        // behind it leaves the screen unswipeable. Accessing `view` loads it
        // so the pan has something to attach to.
        transition.attachInteractiveDismissal(
            to: destination.view, axes: [.horizontal, .vertical]
        ) { [weak nav, weak transition] in
            if let transition { nav?.delegate = transition }
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
        // ⚠️ AFTER THE PUSH, and that is the whole of whether it works. The
        // line above hands the stack's delegate to the flight, so a driver
        // installed before it captures a slot it is about to lose — and a
        // dismissal it never hears about is one UIKit never asks for an
        // interaction controller for, which reads as a dead gesture. Installing
        // here makes the FLIGHT what this driver saves and forwards a `.hero`
        // pop back to. The map's own card-close says the same thing about the
        // same ordering.
        if let gallery = galleryPresenter {
            Self.attachTileCardClose(
                feed: destination, landing: gallery, on: nav, retainer: retainer
            )
        }
    }

    public func makeClusterGallery(
        postIDs: [PostID],
        title: String,
        following: ClusterGalleryFollowing?,
        feed: UIViewController,
        mapReturn: @escaping (@escaping () -> UIImage?) -> (any ZoomTransitionSource)?
    ) -> UIViewController {
        let base = repository
        let engagement = engagementProvider
        let gallery = PlaceProfileViewController(
            postIDs: postIDs,
            placeName: title,
            imagePipeline: imagePipeline,
            videoPlayback: videoPlayback,
            following: following,
            // The same balance the map's toolbar shows under this page, and
            // the same sheet it opens — one wallet instance app-wide, because
            // `WalletStore`'s change post is scoped to the instance.
            wallet: wallet,
            makeWalletSheet: makeWalletSheet,
            loadPosts: {
                // One hydration over the same provider shape the feed above
                // uses, so every member is a cache hit. Unranked: the
                // profile applies its own popularity order
                // (`PlaceProfileViewController.ranked`).
                let provider = FixedPostsFeedProvider(base: base, ids: postIDs)
                var members = try await ForYouRepository(feed: provider).firstPage().posts
                // ⚠️ THE TIMELINE READ HYDRATES LIKES ONLY, and a count this
                // page never asked for is a control this page never draws.
                //
                // The place's VIEWS aggregate needed one projection, so this
                // used to batch that alone — and the COMMENT count stayed
                // absent, which `PostMetricLabel.set(nil)` renders as a hidden
                // chip. The row therefore wore a likes pill and no comment
                // pill, and the shortcut to a media post's thread did not exist
                // on this screen at all. Filmed.
                //
                // One batched read of all three instead, through the same
                // `PostCounterReader` For You and the profile gallery use — the
                // counter is the number the rest of the app reads, so three
                // surfaces asking three different ways is how they come to
                // disagree. Fail-open: a missing read leaves every count as the
                // timeline gave it.
                if let counterClient {
                    let byPostID = await PostCounterReader.counters(
                        forPostIDs: members.map(\.id.rawValue), using: counterClient
                    )
                    if !byPostID.isEmpty {
                        members = members.map { post in
                            guard let counts = byPostID[post.id.rawValue] else { return post }
                            var decorated = post
                            decorated.reactionCount = counts.likes ?? post.reactionCount
                            decorated.commentCount = counts.comments
                            decorated.viewCount = counts.views ?? post.viewCount
                            return decorated
                        }
                    }
                } else if let engagement,
                          let views = try? await engagement.viewCounts(for: members.map(\.id)) {
                    // No counter service wired: keep the view projection this
                    // page's aggregate depends on rather than losing it too.
                    members = members.map { post in
                        var decorated = post
                        decorated.viewCount = views[post.id] ?? post.viewCount
                        return decorated
                    }
                }
                return members
            },
            openPost: { presenter, origin, ids in
                presentSnapFeedHero(postIDs: ids, from: presenter, origin: origin)
            }
        )
        // No `gallery.title`: the place's name lives on the BANNER while the
        // header is expanded and crossfades into the profile's own
        // `navigationItem.titleView` as it docks — a bar title set here would
        // sit at full strength over both.
        gallery.activePostID = { [weak feed] in
            (feed as? SnapFeedViewController)?.activePostID
        }
        gallery.activeCover = { [weak feed] in
            (feed as? any SnapFeedSettleReporting)?.settledCoverImage
        }
        // Eager on purpose: the gallery lives its early life invisible under
        // the feed (a mid-stack insertion never loads its view), and the
        // first anyone sees of it is a dismissal LANDING on it.
        gallery.beginLoading()
        // The page's own way home — staged when it becomes top
        // (`installMapReturnIfTop`): hero to the marker, slide as fallback.
        gallery.mapReturn = mapReturn
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
        pushWithoutFlight(makeSnapFeedViewController(postIDs: postIDs), on: nav, reveal: nil)
    }

    public func revealSnapFeed(
        postIDs: [PostID],
        from presenter: UIViewController,
        origin: TextRevealOrigin,
        beneath: ((UIViewController) -> UIViewController)?
    ) {
        guard !postIDs.isEmpty, let nav = presenter.navigationController else { return }
        pushWithoutFlight(
            makeSnapFeedViewController(postIDs: postIDs),
            on: nav, reveal: origin, beneath: beneath
        )
    }

    /// The reveal's geometry for a CLOSE, built without pushing anything.
    ///
    /// ⚠️ SAFE ON A LOADED FEED, unlike the push — which runs on an empty one
    /// and relies on it. `TextRevealInstaller.geometry` also arms the loading
    /// page, and both of its side effects decline here by construction:
    /// `presentLoadingPage` returns immediately once `orderedIDs` is non-empty,
    /// and the empty ground it sets only ever feeds the resolver's empty
    /// branch.
    ///
    /// Deliberately NOT wrapped in `withDockChoreography`: a caller that owns
    /// its own bottom chrome (the map does) restores it itself, and two owners
    /// would fight over one bar.
    public func makeRevealGeometry(
        dismissing feed: UIViewController,
        origin: TextRevealOrigin,
        onWillClose: (() -> Void)?
    ) -> RevealGeometry {
        (feed as? SnapFeedViewController)?.onWillCloseFeed = onWillClose
        return TextRevealInstaller.geometry(
            feed: feed, origin: origin, pipeline: imagePipeline
        )
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
    private func pushWithoutFlight(
        _ destination: UIViewController,
        on nav: UINavigationController,
        reveal: TextRevealOrigin?,
        beneath: ((UIViewController) -> UIViewController)? = nil
    ) {
        (destination as? SnapFeedViewController)?.zoomOwnsInteractiveDismissal = true
        // A surface that can describe the ROW it is opening from gets the
        // reveal instead of the bare push — the window, not the slide. Every
        // caller of this method reaches it the same way (nothing to fly), so
        // this is the one place a second screen has to be taught.
        let revealing = reveal.map { _ in TextRevealInstaller.isEnabled } ?? false

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

        if let reveal, revealing {
            // THE BAR STAYS UP for frame 0, and that is the whole of it. The
            // dock draws over the grid without insetting it, so at rest it
            // covers the bottom of the row a reveal departs from — measured on
            // an iPhone 17 Pro, 26pt of a 145pt card, which is its entire
            // metric line. Taken down before the push as the branch below does
            // it, that line SNAPS into existence one frame after the mask
            // opens: the card the viewer tapped is not the card that starts
            // growing. Driven by the flight instead, the bar is fully in place
            // when the window is measured and dissolves as the page grows past
            // it, and `presentationDidEnd` retires it for real underneath the
            // landed page where the frame change cannot be seen.
            dismissal.revealReturningChrome = nav.tabBarController?.tabBar
            // Restoring it at alpha 0 BEFORE the pop is triggered settles the
            // grid's layout while nothing is in flight. Inside the transition
            // instead, the bar comes back as a row of empty glass capsules that
            // never paint.
            // ⚠️ ONE RESTORE, TWO WAYS OF LEAVING. The drag announces itself
            // at `onWillBeginPop`; a tapped chevron has no begin at all, and
            // announcing itself is exactly what `onWillCloseFeed` is for. Both
            // land here, outside any transition, which is the whole condition
            // this work has: done inside one, the bar comes back as a state
            // that reads visible on a view that never painted and whose safe
            // area never returns — measured on the map's reveal route as a
            // dock that was "shown" by every API and drawn by none, with the
            // filter pills left 49pt low behind it.
            let restoreDockOffstage: (UINavigationController?) -> Void = { nav in
                nav?.tabBarController?.setTabBarHidden(false, animated: false)
                nav?.tabBarController?.tabBar.alpha = 0
            }
            dismissal.onWillBeginPop = { [weak nav] _ in restoreDockOffstage(nav) }
            (destination as? SnapFeedViewController)?.onWillCloseFeed = { [weak nav] in
                restoreDockOffstage(nav)
            }
            // The OPENING is this reveal's, and it has to say so: a geometry
            // alone no longer means the push is one, now that a media post
            // carries one for the case where the viewer pages onto a text post
            // before closing. See `InteractiveSlideDismissal.revealPresents`.
            dismissal.revealPresents = true
            dismissal.revealGeometry = TextRevealInstaller.geometry(
                feed: destination,
                origin: Self.withDockChoreography(reveal, on: nav),
                pipeline: imagePipeline
            )
        } else {
            // Hidden BY HAND for the same reason the flight path states at
            // length: `hidesBottomBarWhenPushed`'s choreography does not scrub
            // with a custom interactive pop, and this screen now has one.
            nav.tabBarController?.setTabBarHidden(true, animated: true)
        }
        // A place page beneath a semantic cluster's feed: the VERTICAL
        // dismissal's landing, slid under the feed at swipe-begin — the
        // Case-B restaging recipe, inverted (INSERT instead of drop) — so
        // the plain single pop that follows lands on it.
        //
        // THE TWO AXES GO TO DIFFERENT PLACES, and each closes onto what is
        // really there: rightward onto the map's marker, downward onto the
        // post's own card on the place page's Activity tab. One
        // `revealGeometry` cannot describe both, so `prepareForDismissal`
        // swaps it for the live axis — which is early enough by construction,
        // the driver reading the geometry three lines after asking.
        if let beneath {
            // Built NOW and captured STRONGLY: until a vertical swipe
            // inserts it, this closure chain is the page's only owner.
            // Hydration starts inside the builder (`makeClusterGallery`
            // begins loading), so the first dismissal lands on cards rather
            // than a skeleton.
            let landing = beneath(destination)
            // The marker's own geometry, kept for the rightward leg.
            let markerGeometry = dismissal.revealGeometry
            // ⚠️ THE FALLBACK TRAVELS SIDEWAYS whatever the hand did. A
            // downward slide reads as the page being dropped; the platform's
            // back-direction is the honest look for a close that could not
            // stage its card.
            dismissal.fallbackSlideAxis = .horizontal
            dismissal.prepareForDismissal = { [weak landing] axis in
                guard axis == .vertical else {
                    dismissal.revealGeometry = markerGeometry
                    return
                }
                // Nil origin — no card to land on — leaves the geometry nil,
                // which is exactly how the driver selects the plain slide.
                dismissal.revealGeometry = (landing as? PlaceProfileViewController)?
                    .activityCardRevealOrigin(
                        sizedTo: nav.view.bounds,
                        // The post the viewer is on, so the landing can put it
                        // at the head of the list — see the origin's own note.
                        // Read HERE because this closure runs before the driver
                        // takes the geometry, which is the last moment the list
                        // can still be arranged.
                        settled: (destination as? SnapFeedViewController)?.activePostID
                    )
                    .map {
                        TextRevealInstaller.geometry(
                            feed: destination, origin: $0, pipeline: imagePipeline
                        )
                    }
            }
            let staged = dismissal.onWillBeginPop
            dismissal.onWillBeginPop = { [weak nav, weak destination] axis in
                staged?(axis)
                guard axis == .vertical, let nav, let destination,
                      !nav.viewControllers.contains(landing),
                      let feedIndex = nav.viewControllers.firstIndex(of: destination)
                else { return }
                var stack = nav.viewControllers
                stack.insert(landing, at: feedIndex)
                nav.setViewControllers(stack, animated: false)
                // The removal half, for an abandoned swipe: the page leaves
                // again so the back button and the horizontal close keep
                // their map landing. Both hops are load-bearing — the
                // coordinator exists only once the pop has begun (next
                // turn), and its completion fires inside
                // `completeTransition(false)`'s call stack, where a
                // same-turn `setViewControllers` is silently swallowed
                // (measured on the map's escape; see its cancel closure).
                DispatchQueue.main.async { [weak nav, weak destination] in
                    guard let coordinator = destination?.transitionCoordinator else { return }
                    coordinator.animate(alongsideTransition: nil) { context in
                        guard context.isCancelled else { return }
                        DispatchQueue.main.async { [weak nav, weak destination] in
                            guard let nav, let destination,
                                  nav.topViewController === destination,
                                  nav.viewControllers.contains(landing) else { return }
                            var stack = nav.viewControllers
                            stack.removeAll { $0 === landing }
                            nav.setViewControllers(stack, animated: false)
                        }
                    }
                }
            }
        }
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
            // `-zoom-demo-grab-vertical` flips this script to the vertical
            // axis, exactly as it does the zoom demos — the axis a semantic
            // cluster's feed dismisses into its place page on.
            //
            // `-text-swipe-demo-horizontal` overrides it back, for the run that
            // needs BOTH in one process: reach the place page by a vertical
            // dismiss, then leave the post above it sideways. A single
            // process-wide flag cannot say that, which is how this leg went
            // unscripted while the flag was set for the leg before it.
            let axis: ZoomDismissAxis
            if arguments.contains("-text-swipe-demo-horizontal") {
                axis = .horizontal
            } else {
                axis = arguments.contains("-zoom-demo-grab-vertical") ? .vertical : .horizontal
            }
            // Optional second argument: how long to wait. A run that PAGES the
            // feed first has to outlast that paging — a swipe scripted before
            // the pager has settled asks about the post the feed opened on,
            // which is the one case the re-pointing exists for.
            let delay = position + 2 < arguments.count
                ? (Double(arguments[position + 2]) ?? 1.5) : 1.5
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                let driven = await dismissal.debugPerformSwipe(
                    peakProgress: CGFloat(peak), axis: axis
                )
                print("[text-swipe] peak=\(peak) axis=\(axis) driven=\(driven)")
            }
        }
        #endif
    }

    /// Wraps a surface's reveal hooks with the DOCK's own choreography.
    ///
    /// Composed rather than asked of the surface, because the dock belongs to
    /// the navigation shell and not to whichever screen is opening a post — a
    /// profile should no more have to know how the bar is retired than For You
    /// should have to be told where a profile's rows are. Each hook runs both:
    /// the shell's part and the surface's own.
    private static func withDockChoreography(
        _ reveal: TextRevealOrigin, on nav: UINavigationController
    ) -> TextRevealOrigin {
        // `replacingChrome`, never a rebuilt `TextRevealOrigin`. This method
        // used to construct one field by field and dropped four of them —
        // `captionTop`, `authorBand`, `makeDismissStandIn` and `setConcealed` —
        // which are exactly the pieces a profile gallery's reveal was missing
        // while For You's, which does not come through here, had them all.
        reveal.replacingChrome(
            presentationDidEnd: { [weak nav] landed in
                // The flight faded the bar to nothing; take it down for real
                // now. A REVERSED opening never showed the page, so the bar
                // goes back to being the grid's.
                nav?.tabBarController?.setTabBarHidden(landed, animated: false)
                nav?.tabBarController?.tabBar.alpha = 1
                reveal.presentationDidEnd(landed)
            },
            dismissalDidEnd: { [weak nav] committed in
                reveal.dismissalDidEnd(committed)
                // A cancelled swipe leaves the post on screen, so the bar
                // restored at grab-begin has to go back down — unanimated and
                // behind the page that sprang back, where nothing renders the
                // change. Committed pops leave it up; `onFeedPopped` takes it
                // from there.
                guard !committed else { return }
                nav?.tabBarController?.setTabBarHidden(true, animated: false)
            }
        )
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
    ///
    /// ⚠️ The refusal below asks `concealsAppTabBar`, NOT conformance. It used
    /// to test `is any ZoomTransitionDestination` and read that as "another
    /// full-bleed surface is underneath, whose own mechanic owns the dock". The
    /// place page conforms without covering anything, so a feed popping onto it
    /// took this early return and left the viewer on a perfectly ordinary
    /// screen with no dock.
    /// The way back for a post the viewer PAGED onto that has nothing to fly.
    ///
    /// ⚠️ THE PRESENTATION WAS CHOSEN AT THE TAP. A tile opens with a hero;
    /// swipe to a text post and there is no media left for that hero to carry.
    /// Both zoom grabs then refuse — they gate on `zoomDismissalKind != .card`
    /// BEFORE they look at an axis — the pop animator declines for the same
    /// reason, and this push has already disclaimed the stack's native edge
    /// gesture. Measured one level up on the map, where the drag did nothing at
    /// all on either axis and the chevron was the only way out; the map cured
    /// it with `attachCardCloseAlongsideFlight` and this path never got the
    /// equivalent.
    ///
    /// ⚠️ BOTH AXES, like every other card-close.
    ///
    /// It was vertical-only for exactly as long as the horizontal axis had a
    /// second slide on it — the escape past this page to the map, which also
    /// claimed `.card`, and two `InteractiveSlideDismissal`s claiming the same
    /// kind on the same drag is the one thing the arbitration cannot resolve.
    /// The escape is gone; the narrowing outlived it by one commit, and what it
    /// left behind was a page with NOTHING on its horizontal axis: the flight
    /// refuses `.card` before it looks at an axis, and the only driver that
    /// would take it was armed elsewhere. Open a post from Activity, page onto
    /// a text one, swipe right — nothing at all happened. Reported.
    private static func attachTileCardClose(
        feed: UIViewController,
        landing: any CardCloseLanding,
        on nav: UINavigationController,
        retainer: HeroTransitionRetainer
    ) {
        let close = InteractiveSlideDismissal()
        retainer.cardClose = close
        close.resetForNewPresentation()
        close.arbitratesWithHeroGrab = true
        close.attach(to: feed, axes: [.horizontal, .vertical])
        // ⚠️ ONCE. A swipe asks twice — when the grab claims the screen, and
        // again when the pop it triggers asks for an animator — and the staging
        // below MOVES a scroll position and releases a concealment, so a second
        // pass would re-do both against a screen already halfway home.
        var hasPrepared = false
        close.prepareForDismissal = { [weak feed, weak landing, weak close] _ in
            guard !hasPrepared, let feed, let landing, let close else { return }
            // ⚠️ ONLY FOR A CLOSE THAT CARRIES A CARD. This runs for every
            // dismissal including the flight's, and the staging conceals the
            // landing — a flight arriving on a hidden tile reads as no
            // animation at all. Asked of the same authority both grabs gate on,
            // so the three can never disagree about what the post is.
            guard (feed as? any ZoomTransitionDestination)?.zoomDismissalKind == .card
            else { return }
            hasPrepared = true
            close.revealGeometry = landing.cardCloseGeometry(dismissing: feed)
        }
        // The backstop: whatever animated the close, nothing stays hidden. The
        // staging conceals a tile and only the reveal's own completion pays
        // that back, so a pop finished by anything else would leave a hole.
        close.onFeedPopped = { [weak landing] _ in
            landing?.clearLandingConcealment()
            retainer.cardClose = nil
        }
        // AFTER the push, so the flight controller is what `install` captures
        // and a `.hero` pop forwards straight back to it.
        close.install(on: nav)
        #if DEBUG
        // `-tile-card-close-demo <peak>`: the driver's OWN scripted route.
        //
        // Nothing else can reach it. `debugScriptedGrab` picks among the ZOOM
        // drivers, every one of which refuses `.card` before it looks at an
        // axis; `-text-swipe-demo` is bound to whichever slide its own block
        // closes over, and this one has no block. A driver with no scripted
        // route is a driver nobody verifies — the hole that had just been
        // closed for the neighbouring leg.
        let arguments = ProcessInfo.processInfo.arguments
        if let position = arguments.firstIndex(of: "-tile-card-close-demo"),
           position + 1 < arguments.count,
           let peak = Double(arguments[position + 1]) {
            // Optional second argument: how long to wait. The default is the
            // usual beat after the push, but a run that pages the feed first
            // has to outlast that paging — a swipe scripted before the pager
            // has SETTLED asks about the post the feed opened on, which is the
            // one row this driver is not for.
            let delay = position + 2 < arguments.count
                ? (Double(arguments[position + 2]) ?? 2.5) : 2.5
            Task { @MainActor [weak close, weak feed] in
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                // The three things that decide whether this driver may claim
                // the drag at all, said before it tries: a refusal and a
                // failure look identical from the outside.
                let kind = (feed as? any ZoomTransitionDestination)?.zoomDismissalKind
                // Both axes carry this driver now, so a run has to be able to
                // ask for either — the defect that put them back was one axis
                // silently having no tenant at all.
                let axis: ZoomDismissAxis = arguments
                    .contains("-tile-card-close-demo-horizontal") ? .horizontal : .vertical
                let driven = await close?.debugPerformSwipe(
                    peakProgress: CGFloat(peak), axis: axis
                )
                let settled = (feed as? any SnapFeedSettleReporting)?.settledPostID
                print("[tile-card-close] peak=\(peak) axis=\(axis) settled=\(settled?.rawValue ?? "nil")"
                    + " kind=\(kind.map(String.init(describing:)) ?? "nil")"
                    + " geometry=\(close?.revealGeometry != nil) driven=\(driven ?? false)")
            }
        }
        #endif
    }

    private static func restoreTabBar(on nav: UINavigationController?) {
        #if DEBUG
        // `-grab-log`: the bar's TWO states at the one moment it is supposed
        // to be back. `hidden=false viewHidden=true` is the whole of the defect
        // below — a bar every API reports as shown and nothing draws — and it
        // is invisible from anywhere else.
        if ProcessInfo.processInfo.arguments.contains("-grab-log") {
            print("[pop] restoreTabBar top="
                + (nav?.topViewController.map { String(describing: type(of: $0)) } ?? "nil")
                + " hidden=\(String(describing: nav?.tabBarController?.isTabBarHidden))"
                + " alpha=\(String(describing: nav?.tabBarController?.tabBar.alpha))"
                + " viewHidden=\(String(describing: nav?.tabBarController?.tabBar.isHidden))")
        }
        #endif
        guard let nav, let tabs = nav.tabBarController,
              (nav.topViewController as? any ZoomTransitionDestination)?.concealsAppTabBar != true
        else { return }
        tabs.tabBar.alpha = 1
        // Idempotent, because the screen underneath may have got there first:
        // a tab ROOT asserts its own dock on the far side of a committed scrub
        // (`ProfileViewController.revealDock`), and the two orders are not
        // guaranteed. Whichever arrives first animates; the second finds the bar
        // already down and re-asserts it without a second animation.
        // ⚠️ AND IT ONLY EVER ANIMATES A BAR THAT IS ACTUALLY HIDDEN. When
        // the state already reads visible there is nothing here to repair —
        // and repairing it here is the wrong place anyway: a bar restored
        // while a transition is running comes back as a state nothing draws,
        // with its safe-area contribution never returning. The cure is to
        // restore it BEFORE the pop, which is what `onWillCloseFeed` and
        // `onWillBeginPop` are both for.
        guard tabs.isTabBarHidden else { return }
        tabs.setTabBarHidden(false, animated: true)
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
            #if DEBUG
            let maySeed = !Self.isColdOpenForced
            #else
            let maySeed = true
            #endif
            if maySeed, cached.count == postIDs.count, !cached.isEmpty {
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
                // A feed pushed before its corpus has nothing to draw for as
                // long as this Task takes. Arm the ARRIVAL screen's own loading
                // state; the text-reveal installer is what draws it. For a
                // cluster this is the representative, which leads `memberIDs` —
                // one skeleton page, never N.
                if let head = postIDs.first { snapFeed.armLoadingPage(for: head) }
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
            makeWalletSheet: makeWalletSheet,
            // For the ⋯ menu's Report row, which withholds itself when there is
            // nobody to file with — the same rule the grid's card menu follows.
            reporting: reporting
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
    /// The VERTICAL card-shaped close of a gallery-opened post — the way back
    /// for a page the viewer swiped onto that has no media to fly. Nil'd by
    /// both close-outs, because the flight's return and the escape's landing
    /// are two different exits and either can be the last one.
    var cardClose: InteractiveSlideDismissal?
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
