import CoreModels
import CoreNavigation
import CoreStorage
import EntityStore
import FeedInterface
import MediaCore
import MediaPlayback
import PostGrid
import PostSurfaces
import ShareSheet
import UIKit

/// The Snap feed's assembly: the feed's one construction and the three ways
/// a post opens into it (the hero flight, the plain push and the window),
/// with the dock's backstops. One type over four files: this one,
/// `+HeroOpening`, `+PlainOpening` and `+Dock`. Built once by
/// `FeedFeatureBuilder`.
@MainActor
struct SnapFeedAssembly {
    private let repository: any FeedProviding
    private let engagementProvider: (any EngagementProviding)?
    private let commentsProvider: (any CommentsProviding)?
    private let realtime: (any FeedRealtimeSubscribing)?
    private let composedPosts: ComposedPostChannel
    private let router: any Router
    let imagePipeline: ImagePipeline
    private let videoPlayback: VideoPlaybackController?
    /// The viewer's point balance, shared with every surface that shows or
    /// spends it (the map toolbar's badge, the rail's boost anchor, the
    /// comments bar). One instance app-wide — `WalletStore`'s change post is
    /// scoped to the instance. Nil leaves the boost buttons inert.
    private let wallet: (any WalletStaking)?
    /// Vends the wallet/claim sheet for the feed header's balance badge —
    /// injected because the sheet is shell-owned (it is the same one the
    /// map's badge presents, and the two must never diverge). Nil leaves
    /// the feed's badge display-only, the pre-sheet behaviour.
    private let makeWalletSheet: (@MainActor () -> UIViewController)?
    /// Whether the viewer is shown a balance at all — asked as each screen is
    /// built. A guest is not (#1146, the owner 2026-10-14): no badge on any
    /// bar. The wallet itself still backs the like controls, whose spend a
    /// guest only reaches by signing up.
    private let showsBalance: @MainActor () -> Bool
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
    /// Whether the viewer follows a post's author — the snap feed's author
    /// pill offers its "+" only to someone the viewer does not follow yet, and
    /// follows them through `socialGraph`. Nil (or a nil `socialGraph`): no "+".
    private let followRelations: (any SocialGraphReading)?
    /// The app's one follow-change channel, so the pill's "+" agrees with a
    /// follow or unfollow made on any other surface.
    private let followEvents: FollowGraphEvents
    /// The app's one post and profile per id (#896): every snap feed reads
    /// the viewer's relation to an author from it, so a follow on one feed
    /// is the badge of all of them.
    private let entities: any EntityReading & EntityWriting
    /// The posts the server withholds from this viewer, learnt on any feed
    /// (#2048): every feed and the For You grid drop the ones not on show.
    /// The app's one record (#2376).
    private let unavailablePosts: UnavailablePosts
    /// The viewer's saved pile (#837): the app's one (#2376), which every
    /// feed, card and grid page this root builds reads and writes.
    private let bookmarks: PostBookmarkStore
    /// What the viewer viewed (#1344): every vertical feed records into the
    /// app's one pile, which the profile's History tab reads (#2376).
    private let viewHistory: PostViewHistoryStore
    /// The sounds the viewer saved, for the sound sheet's star (#2376).
    private let savedSounds: SavedSoundStore
    /// The profile using the app, for the author marks: its own posts wear no
    /// badge from the first frame (#2098).
    private let viewerProfile: @MainActor () -> ProfileID?
    /// Which sound a clip is set to, for the sound sheet. Nil: every clip is
    /// its own "original sound", played straight from the clip.
    private let soundProvider: (any PostSoundProviding)?
    /// "Use this sound" — the shell opens its camera with it. Nil hides the
    /// button: an action that cannot act is not offered.
    private let useSound: (@MainActor (PostSound) -> Void)?
    private let discovery: (any FeedProviding)?
    private let shareTargeting: (any ShareTargeting)?
    /// The builder's one warm of a post's first comments (#2002).
    private let postOpenWarm: PostOpenWarm?
    private let comments: PostCommentsAssembly
    private let heldPosts: FeedHeldPosts

    init(
        dependencies: FeedFeatureBuilder.Dependencies, postOpenWarm: PostOpenWarm?,
        comments: PostCommentsAssembly, heldPosts: FeedHeldPosts
    ) {
        repository = dependencies.repository
        engagementProvider = dependencies.engagementProvider
        commentsProvider = dependencies.commentsProvider
        realtime = dependencies.realtime
        composedPosts = dependencies.composedPosts
        router = dependencies.router
        imagePipeline = dependencies.imagePipeline
        videoPlayback = dependencies.videoPlayback
        wallet = dependencies.wallet
        makeWalletSheet = dependencies.makeWalletSheet
        showsBalance = dependencies.showsBalance
        reporting = dependencies.reporting
        socialGraph = dependencies.socialGraph
        followRelations = dependencies.followRelations
        followEvents = dependencies.followEvents
        entities = dependencies.entities
        unavailablePosts = dependencies.unavailablePosts
        bookmarks = dependencies.bookmarks
        viewHistory = dependencies.viewHistory
        savedSounds = dependencies.savedSounds
        viewerProfile = dependencies.viewerProfile
        soundProvider = dependencies.soundProvider
        useSound = dependencies.useSound
        discovery = dependencies.discovery
        shareTargeting = dependencies.shareTargeting
        self.postOpenWarm = postOpenWarm
        self.comments = comments
        self.heldPosts = heldPosts
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
                router: router,
                entities: entities,
                unavailablePosts: unavailablePosts
            )
        )
    }

    public func makeSnapFeedViewController(
        postIDs: [PostID],
        ownsInteractiveDismissal: Bool
    ) -> UIViewController {
        makeSnapFeedViewController(postIDs: postIDs, ownsInteractiveDismissal: ownsInteractiveDismissal, continuation: nil)
    }

    public func makeSnapFeedViewController(
        postIDs: [PostID],
        ownsInteractiveDismissal: Bool,
        sourceIsComplete: Bool
    ) -> UIViewController {
        makeSnapFeedViewController(
            postIDs: postIDs, ownsInteractiveDismissal: ownsInteractiveDismissal,
            continuation: nil, isCompleteSet: sourceIsComplete
        )
    }

    /// The feed over a window of posts — and, with `continuation`, on past it
    /// into the source's next posts (#638). `isCompleteSet`: the window is the
    /// whole source, so its last post is the end (#628).
    func makeSnapFeedViewController(
        postIDs: [PostID],
        ownsInteractiveDismissal: Bool,
        continuation: SnapFeedContinuation?,
        isCompleteSet: Bool = false
    ) -> UIViewController {
        // ⚠️ THE LAST RESORT (#2002): every opener builds its feed here, so a
        // post whose tile never warmed it (a link, a notification, a tap
        // that beat the warm) asks for its first comments now. Late for the
        // flight, early for the landing; a post already held asks nothing.
        if let opened = postIDs.first { postOpenWarm?.warmNow([opened]) }
        let feed = makeSnapFeed(
            viewModel: FeedViewModel(
                // One kind per feed (#1421): the opening post's, through the
                // window and every continuation page.
                repository: FixedPostsFeedProvider(
                    base: repository, ids: postIDs, continuation: continuation, isCompleteSet: isCompleteSet,
                    keepsToOpeningKind: true,
                    // The kind it was opened as, should the opening post not
                    // come back (#2048).
                    openingKind: postIDs.first.flatMap(heldPosts.heldEntry).map(SnapFeedKindScope.init)
                ),
                engagementProvider: engagementProvider,
                commentsProvider: commentsProvider,
                router: router,
                entities: entities,
                unavailablePosts: unavailablePosts
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
            // The store answers what the mirror does not (#1862): a push or a
            // link to a post held on the device opens on the post.
            let cached = postIDs.compactMap { heldPosts.heldEntry($0) }
            #if DEBUG
            let maySeed = !FeedPlaybackWarms.isColdOpenForced
            #else
            let maySeed = true
            #endif
            if maySeed, let opening = postIDs.first, cached.first?.post.id == opening {
                // ⚠️ WHAT IS KNOWN, AS LONG AS THE OPENING POST IS (#1863). A
                // cluster with one cold member used to take the whole async
                // path. The seed is the set's held members in its order; the
                // view model's own first page (`FixedPostsFeedProvider`, the
                // whole window, concurrently) then replaces it and the late
                // members arrive in their places through the snapshot — the
                // "second seed is ignored" contract never has to admit them
                // (`SnapFeedViewController.seedProjection`).
                snapFeed.seedProjection(SnapFeedViewController.keepingOpeningKind(
                    FeedDisplayModelBuilder().build(cached, relativeTo: Date())
                ))
            } else {
                // The opening post is unknown: its loading page, as before.
                // A feed pushed before its corpus has nothing to draw for as
                // long as this Task takes. Arm the ARRIVAL screen's own loading
                // state; the text-reveal installer is what draws it. For a
                // cluster this is the representative, which leads `memberIDs` —
                // one skeleton page, never N.
                if let head = postIDs.first { snapFeed.armLoadingPage(for: head) }
                let repository = repository
                Task { @MainActor [weak snapFeed] in
                    // Concurrently (#1863): five cold members were five round
                    // trips in a row.
                    let entries = await FeedHeldPosts.loadConcurrently(postIDs, from: repository)
                    guard !entries.isEmpty else { return }
                    snapFeed?.seedProjection(SnapFeedViewController.keepingOpeningKind(
                        FeedDisplayModelBuilder().build(entries, relativeTo: Date())
                    ))
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
        let imagePipeline = imagePipeline
        let wallet = wallet
        let makeWalletSheet = makeWalletSheet
        // One session for the page and the comments panels it embeds (#2532).
        let stakes = wallet.map { StakeSession(wallet: $0) }
        let makePanel = comments.makePanelFactory(sharing: stakes)
        let feed = SnapFeedViewController(
            viewModel: viewModel,
            imagePipeline: imagePipeline,
            videoPlayback: videoPlayback,
            // Every page's comments are this one panel (`.comments` opens the
            // vertical feed with them up, #1577). Text-only pages host the
            // SAME panel (their engaged card
            // carries the post, exactly like media pages).
            makeCommentsPanelContent: { postID in makePanel(postID, false) },
            // A TEXT page's resting comments carry the day pills and the lifted
            // menu; media pages keep the panel above.
            makeRestingCommentsPanelContent: { postID in makePanel(postID, true) },
            wallet: wallet,
            stakes: stakes,
            makeWalletSheet: makeWalletSheet,
            showsBalance: showsBalance(),
            // For the ⋯ menu's Report row, which withholds itself when there is
            // nobody to file with — the same rule the grid's card menu follows.
            reporting: reporting,
            // The author pill's "+": offered to someone the viewer does not
            // follow yet, and a tap follows them — the same repositories the
            // profile's Follow button writes through.
            socialGraph: socialGraph,
            followRelations: followRelations,
            followEvents: followEvents,
            entities: entities,
            bookmarks: bookmarks,
            savedSounds: savedSounds,
            viewer: viewerProfile,
            soundProvider: soundProvider,
            useSound: useSound,
            // The sound sheet's grid opens a NEW feed of the posts with that
            // sound, with the same hero every grid in the app flies.
            openFeedHero: { [self] ids, presenter, origin in
                presentSnapFeedHero(postIDs: ids, from: presenter, origin: origin)
            },
            galleryPost: { [self] id in heldPosts.heldEntry(id).map(DiscoverRepository.galleryPost(from:)) },
            // …and the posts the grid lists from outside the feed: loaded into
            // the same cache, which `galleryPost` then answers from.
            prewarmPosts: { ids in await repository.prewarm(ids) }
        )
        // Every vertical feed records what the viewer viewed (#1344).
        feed.viewHistory = viewHistory
        // The side list's posts (#1425, #1473): the Discover pool
        // (`DiscoveryFeedRepository`) as the app already holds it, else as it
        // loads; the feed's own repository when there is no pool.
        let source: any FeedProviding = discovery ?? repository
        // Its share sheet's people (#1710).
        feed.shareTargeting = shareTargeting
        feed.sideListEntries = {
            if let cached = await source.cachedFirstPage(), !cached.isEmpty { return cached }
            return (try? await source.loadFirstPage())?.entries ?? []
        }
        // The side list's and the sound sheet's posts warm their first
        // comments (#2002).
        feed.postOpenWarm = postOpenWarm
        return feed
    }

    public func makePostFeedViewController(for postID: PostID, opensComments: Bool) -> UIViewController {
        let feed = makeSnapFeedViewController(postIDs: [postID], ownsInteractiveDismissal: false)
        // Before the push, so the page opens already in its thread
        // (`openComments`'s own rule).
        if opensComments { (feed as? SnapFeedViewController)?.openComments(for: postID) }
        return feed
    }
}
