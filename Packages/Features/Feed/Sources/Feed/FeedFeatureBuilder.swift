import MediaCore
import CoreModels
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

    public init(
        repository: any FeedProviding,
        engagementProvider: (any EngagementProviding)? = nil,
        commentsProvider: (any CommentsProviding)? = nil,
        realtime: (any FeedRealtimeSubscribing)? = nil,
        composedPosts: ComposedPostChannel? = nil,
        router: (any Router)? = nil,
        imagePipeline: ImagePipeline,
        videoPlayback: VideoPlaybackController? = nil,
        makeProfileSwitcher: (@MainActor () -> (any ProfileSwitcherPresenting)?)? = nil
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
        // The snap feed is the only thing this builds, and it conforms — but
        // the factory is typed `UIViewController` for callers who do not care.
        guard let flyable = destination as? any ZoomTransitionDestination else { return }
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
        nav.delegate = transition
        nav.pushViewController(destination, animated: true)
    }

    public func makeSnapFeedViewController(postIDs: [PostID]) -> UIViewController {
        makeSnapFeed(
            viewModel: FeedViewModel(
                repository: FixedPostsFeedProvider(base: repository, ids: postIDs),
                engagementProvider: engagementProvider,
                commentsProvider: commentsProvider,
                router: router
            )
        )
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
                    profileSwitcher: makeProfileSwitcher?()
                )
            }
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
            mode: mode
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
