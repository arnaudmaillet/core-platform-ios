import MediaCore
import CoreContracts
import CoreModels
import CoreNetworking
import CoreStorage
import EntityStore
import PostSurfaces
import ProfileInterface
import CoreNavigation
import Transitions
import FeedInterface
import MediaPlayback
import PostGrid
import ShareSheet
import ThreadKit
import UIKit
import LaunchArguments

/// The feed feature's entry point, resolved by the composition root and
/// consumed through `FeedFeatureBuilding` by the app shell.
@MainActor
public struct FeedFeatureBuilder: FeedFeatureBuilding {
    /// Everything Feed needs, handed in by the composition root (#2375).
    /// Nothing has a default: forgetting a collaborator fails to compile.
    /// The ones the app always wires and the screens can't do without are
    /// required. An optional one is either absent in production (said on
    /// it) or one whose absence is a screen's documented fallback — a row
    /// withheld, a counter hidden — which the app always fills and the
    /// package's tests leave out.
    public struct Dependencies {
        /// The timeline: posts, their pages and the feed's own mirror.
        public var repository: any FeedProviding
        /// Likes and their counts. Nil (a test): the counts stay as loaded.
        public var engagementProvider: (any EngagementProviding)?
        /// A post's comments, and the warm of its first ones (#2002). Nil (a
        /// test): no comments, and no warm.
        public var commentsProvider: (any CommentsProviding)?
        /// Live updates. Nil (a test): the feed reads only what it asks for.
        public var realtime: (any FeedRealtimeSubscribing)?
        /// The posts the viewer just composed, prepended where they belong.
        public var composedPosts: ComposedPostChannel
        public var router: any Router
        public var imagePipeline: ImagePipeline
        /// The app's one player pool. Nil (a test): stills, and no warm.
        public var videoPlayback: VideoPlaybackController?
        /// Vends the profile switcher for the comments composer's avatar
        /// menu: a factory, one switcher per surface. A nil switcher leaves
        /// the composer's face inert.
        public var makeProfileSwitcher: @MainActor () -> (any ProfileSwitcherPresenting)?
        /// The viewer's point balance, shared with every surface that shows
        /// or spends it. Nil (a test): the boost buttons are inert.
        public var wallet: (any WalletStaking)?
        /// The wallet/claim sheet the balance badge opens: the shell's, the
        /// map's own. Nil (a test): the badge is display-only.
        public var makeWalletSheet: (@MainActor () -> UIViewController)?
        /// Whether the viewer is shown a balance at all — asked as each
        /// screen is built. A guest is not (#1146).
        public var showsBalance: @MainActor () -> Bool
        /// Files moderation reports from a post card's "...". Nil (a test):
        /// no Report row.
        public var reporting: (any ContentReporting)?
        /// Follows an author: the pill's "+" and the menu's Unfollow. Nil (a
        /// test): neither.
        public var socialGraph: (any SocialGraphWriting)?
        /// Whether the viewer follows an author. Nil (a test): no "+".
        public var followRelations: (any SocialGraphReading)?
        /// The app's one follow-change channel, so the pill's "+" agrees with
        /// a follow made on any other surface.
        public var followEvents: FollowGraphEvents
        /// The numbers the timeline does not carry, so a card can show reach.
        /// Nil (a test): the cards hide their counter.
        public var postCounters: (any PostCounterReading)?
        /// The Text Post page's drafts: the app's one store.
        public var postDrafts: PostDraftStore
        /// Which sound a clip is set to, for the sound sheet. Nil on the
        /// local fleet, whose post contract carries no audio yet: every clip
        /// is its own "original sound".
        public var soundProvider: (any PostSoundProviding)?
        /// "Use this sound" — the shell opens its camera with it. Nil (a
        /// test): the button is hidden.
        public var useSound: (@MainActor (PostSound) -> Void)?
        /// Discover's own corpus (`GetDiscoveryFeed`). Nil (a test):
        /// Discover is the following timeline.
        public var discovery: (any FeedProviding)?
        /// For You's corpora on the device (#893). Nil when the device store
        /// can't be opened: the tab opens on skeletons.
        public var localCache: FeedLocalCache?
        /// The app's one post and profile per id (#896).
        public var entities: any EntityReading & EntityWriting
        /// The post share sheet's quick-send row (#1710). Nil (a test): the
        /// sheet has no row of people.
        public var shareTargeting: (any ShareTargeting)?
        /// The app's one saved pile, viewing history, record of withheld
        /// posts and saved sounds (#2376).
        public var bookmarks: PostBookmarkStore
        public var viewHistory: PostViewHistoryStore
        public var unavailablePosts: UnavailablePosts
        public var savedSounds: SavedSoundStore
        /// The active profile, as the app's storage scope holds it.
        public var viewerProfile: @MainActor () -> ProfileID?

        public init(
            repository: any FeedProviding,
            engagementProvider: (any EngagementProviding)?,
            commentsProvider: (any CommentsProviding)?,
            realtime: (any FeedRealtimeSubscribing)?,
            composedPosts: ComposedPostChannel,
            router: any Router,
            imagePipeline: ImagePipeline,
            videoPlayback: VideoPlaybackController?,
            makeProfileSwitcher: @escaping @MainActor () -> (any ProfileSwitcherPresenting)?,
            wallet: (any WalletStaking)?,
            makeWalletSheet: (@MainActor () -> UIViewController)?,
            showsBalance: @escaping @MainActor () -> Bool,
            reporting: (any ContentReporting)?,
            socialGraph: (any SocialGraphWriting)?,
            followRelations: (any SocialGraphReading)?,
            followEvents: FollowGraphEvents,
            postCounters: (any PostCounterReading)?,
            postDrafts: PostDraftStore,
            soundProvider: (any PostSoundProviding)?,
            useSound: (@MainActor (PostSound) -> Void)?,
            discovery: (any FeedProviding)?,
            localCache: FeedLocalCache?,
            entities: any EntityReading & EntityWriting,
            shareTargeting: (any ShareTargeting)?,
            bookmarks: PostBookmarkStore,
            viewHistory: PostViewHistoryStore,
            unavailablePosts: UnavailablePosts,
            savedSounds: SavedSoundStore,
            viewerProfile: @escaping @MainActor () -> ProfileID?
        ) {
            self.repository = repository
            self.engagementProvider = engagementProvider
            self.commentsProvider = commentsProvider
            self.realtime = realtime
            self.composedPosts = composedPosts
            self.router = router
            self.imagePipeline = imagePipeline
            self.videoPlayback = videoPlayback
            self.makeProfileSwitcher = makeProfileSwitcher
            self.wallet = wallet
            self.makeWalletSheet = makeWalletSheet
            self.showsBalance = showsBalance
            self.reporting = reporting
            self.socialGraph = socialGraph
            self.followRelations = followRelations
            self.followEvents = followEvents
            self.postCounters = postCounters
            self.postDrafts = postDrafts
            self.soundProvider = soundProvider
            self.useSound = useSound
            self.discovery = discovery
            self.localCache = localCache
            self.entities = entities
            self.shareTargeting = shareTargeting
            self.bookmarks = bookmarks
            self.viewHistory = viewHistory
            self.unavailablePosts = unavailablePosts
            self.savedSounds = savedSounds
            self.viewerProfile = viewerProfile
        }

        /// The wallet a screen's BADGE reads: none for a guest.
        @MainActor var balanceWallet: (any WalletStaking)? { showsBalance() ? wallet : nil }
    }

    private let repository: any FeedProviding
    /// Every surface's warm of a post's first comments, before it is opened
    /// (#2002): one instance, so nothing is asked twice across surfaces.
    /// A class, so every copy of this builder shares it.
    /// Shared with the place page (#2381).
    public let postOpenWarm: PostOpenWarm?
    private let videoPlayback: VideoPlaybackController?

    /// The lists' author bands' relation mark and "+" (#2300): ONE binding
    /// for every surface this root builds — For You, the place page, a post
    /// set, a profile's page — over the same store and follow as the feed's
    /// author rows. A reference, so every copy of this builder shares it.
    /// Shared with the place page (#2381).
    public let authorMarks: PostAuthorMarks
    /// The posts the app holds, and their loads (#1862, #1863).
    private let heldPosts: FeedHeldPosts
    /// The Snap feed: its construction and its openings.
    private let snapFeed: SnapFeedAssembly
    /// The grids the builder lends to Profile, Chat and Search.
    private let grids: PostGridsAssembly
    /// The "+" menu's Text Post and a channel's "Share as a Post".
    private let textPost: TextPostAssembly
    /// The keys For You's content contexts were stored under (#1423): the
    /// feature is gone, and so is the stored choice — no device keeps a dead
    /// value. A second launch finds nothing to remove.
    static let retiredContextKeys = ["foryou.context.v2", "foryou.context"]

    static func forgetRetiredForYouModes(in defaults: UserDefaults) {
        for key in retiredContextKeys { defaults.removeObject(forKey: key) }
    }

    public init(dependencies: Dependencies) {
        postCounters = dependencies.postCounters
        authorMarks = PostAuthorMarks(
            writer: dependencies.socialGraph, reader: dependencies.followRelations, entities: dependencies.entities,
            followEvents: dependencies.followEvents, viewer: dependencies.viewerProfile
        )
        repository = dependencies.repository
        postOpenWarm = dependencies.commentsProvider.map { provider in
            PostOpenWarm(
                prefetch: { id in await provider.prefetchTopComments(for: id) },
                isHeld: { id in provider.holdsComments(for: id) },
                // One call per page of tiles first (#2003).
                previews: { ids in await provider.prefetchPreviews(for: ids) }
            )
        }
        videoPlayback = dependencies.videoPlayback
        heldPosts = FeedHeldPosts(dependencies: dependencies)
        let comments = PostCommentsAssembly(dependencies: dependencies)
        snapFeed = SnapFeedAssembly(
            dependencies: dependencies, postOpenWarm: postOpenWarm, comments: comments, heldPosts: heldPosts
        )
        grids = PostGridsAssembly(
            dependencies: dependencies, postOpenWarm: postOpenWarm, authorMarks: authorMarks,
            snapFeed: snapFeed, heldPosts: heldPosts
        )
        textPost = TextPostAssembly(dependencies: dependencies)
        Self.forgetRetiredForYouModes(in: .standard)
        // Every grid's tiles follow the feed's playback policy — Autoplay,
        // the network, Low Power Mode — For You's and a profile's alike (#580).
        GridVideoPlaybackCoordinator.allowsAutoplay = { MediaPlaybackPolicy.autoplays }
    }

    // The posts the app holds: `FeedHeldPosts`.
    public func galleryPosts(_ ids: [PostID]) async -> [PostID: GalleryPost] {
        await heldPosts.galleryPosts(ids)
    }

    @MainActor
    public func heldGalleryPost(_ id: PostID) -> GalleryPost? {
        heldPosts.heldGalleryPost(id)
    }

    nonisolated static func loadConcurrently(_ ids: [PostID], from repository: any FeedProviding) async -> [FeedEntry] {
        await FeedHeldPosts.loadConcurrently(ids, from: repository)
    }

    static func entry(_ id: PostID, in store: any EntityReading) -> FeedEntry? {
        FeedHeldPosts.entry(id, in: store)
    }

    /// Starts `postID`'s page player now, at `seconds` into its clip — a finger
    /// has landed on its map marker (#646). Nil when the post is not hydrated
    /// yet (the map warms visible posts' DATA on every settle, so it usually
    /// is), when it is not a single clip, when autoplay is off, or without a
    /// player pool. The caller ends it: see `FlightPlaybackWarm.end(opened:)`.
    @MainActor
    public func warmPlayback(of postID: PostID, at seconds: TimeInterval?) -> (any FeedPlaybackWarm)? {
        let entry = repository.peekPost(postID)
        // Not gated on autoplay (#702): the flight lands on a full-screen post,
        // which plays whatever Autoplay says.
        guard let videoPlayback, let entry,
              let clip = FlightPlaybackWarm.warmableClip(of: entry) else {
            #if DEBUG
            if LaunchArgument.zoomLiveLog.isPassed() {
                print("[zoom-live] warm refused \(postID.rawValue): pool=\(videoPlayback != nil) "
                      + "autoplay=\(MediaPlaybackPolicy.autoplays) hydrated=\(entry != nil) "
                      + "attachments=\(entry?.post.attachments.map { $0.mimeType } ?? [])")
            }
            #endif
            return nil
        }
        let warm = FlightPlaybackWarm(pool: videoPlayback, url: clip.url, scope: clip.scope)
        warm.start(at: seconds)
        return warm
    }

    /// See `FeedFeatureBuilding.prerollPlayback` (#654).
    @MainActor
    public func prerollPlayback(of postID: PostID, at seconds: TimeInterval?) -> (any FeedPlaybackWarm)? {
        let process = ProcessInfo.processInfo
        let allowed = FlightPlaybackWarm.prerollAllowed(preloads: MediaPlaybackPolicy.preloads,
                                                        autoplays: MediaPlaybackPolicy.autoplays,
                                                        lowPower: process.isLowPowerModeEnabled,
                                                        thermal: process.thermalState)
        let entry = repository.peekPost(postID)
        // Not hydrated yet: the map warms its visible posts' data on the same
        // settle, and which ones a sweep reaches is not guaranteed. Asked for
        // here, so the map's next try finds it.
        if allowed, entry == nil {
            let repository = repository
            Task { await repository.prewarm([postID]) }
        }
        guard allowed, let videoPlayback, let entry,
              let clip = FlightPlaybackWarm.warmableClip(of: entry) else {
            #if DEBUG
            if LaunchArgument.zoomLiveLog.isPassed(in: process.arguments) {
                print("[zoom-live] preroll refused \(postID.rawValue): preloads=\(MediaPlaybackPolicy.preloads) "
                      + "autoplay=\(MediaPlaybackPolicy.autoplays) lowPower=\(process.isLowPowerModeEnabled) "
                      + "thermal=\(process.thermalState.rawValue) hydrated=\(entry != nil)")
            }
            #endif
            return nil
        }
        let warm = FlightPlaybackWarm(pool: videoPlayback, url: clip.url, scope: clip.scope)
        warm.start(at: seconds, pausedOnFirstFrame: true)
        return warm
    }

    public func prewarmPosts(_ ids: [PostID]) async {
        #if DEBUG
        // See `isColdOpenForced`: a warmed corpus seeds synchronously and the
        // cold path is unreachable, which is why it could only be filmed by
        // accident on a slow machine.
        guard !Self.isColdOpenForced else { return }
        #endif
        // The map's visible pins and the sound sheet's posts warm their first
        // comments too, queued behind what is on screen elsewhere (#2002).
        postOpenWarm?.warmLater(ids)
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
        LaunchArgument.feedColdOpen.isPassed()
    }
    #endif

    private let postCounters: (any PostCounterReading)?

    /// Whether `presenter` may open a post now: its stack is at rest and it
    /// is (inside) the screen on top. What For You and the post list check
    /// before they begin a playback handoff, in one place for the screens
    /// that open through this builder.
    public static func canOpen(from presenter: UIViewController, on nav: UINavigationController) -> Bool {
        PostOpening.canOpen(from: presenter, on: nav)
    }

    // The Snap feed's construction and openings: `SnapFeedAssembly`.
    public func makeFeedViewController() -> UIViewController {
        snapFeed.makeFeedViewController()
    }

    public func presentSnapFeedHero(
        postIDs: [PostID],
        from presenter: UIViewController,
        origin: SnapFeedHeroOrigin
    ) {
        snapFeed.presentSnapFeedHero(postIDs: postIDs, from: presenter, origin: origin)
    }

    public func pushSnapFeed(postIDs: [PostID], from presenter: UIViewController) {
        snapFeed.pushSnapFeed(postIDs: postIDs, from: presenter)
    }

    public func pushSnapFeed(postIDs: [PostID], from presenter: UIViewController, sourceIsComplete: Bool) {
        snapFeed.pushSnapFeed(postIDs: postIDs, from: presenter, sourceIsComplete: sourceIsComplete)
    }

    public func pushSnapFeed(
        postIDs: [PostID], from presenter: UIViewController, sourceIsComplete: Bool,
        beneath: ((UIViewController) -> UIViewController)?
    ) {
        snapFeed.pushSnapFeed(postIDs: postIDs, from: presenter, sourceIsComplete: sourceIsComplete, beneath: beneath)
    }

    public func revealSnapFeed(
        postIDs: [PostID],
        from presenter: UIViewController,
        origin: TextRevealOrigin,
        beneath: ((UIViewController) -> UIViewController)?
    ) {
        snapFeed.revealSnapFeed(postIDs: postIDs, from: presenter, origin: origin, beneath: beneath)
    }

    public func revealSnapFeed(
        postIDs: [PostID],
        from presenter: UIViewController,
        origin: TextRevealOrigin,
        beneath: ((UIViewController) -> UIViewController)?,
        sourceIsComplete: Bool
    ) {
        snapFeed.revealSnapFeed(
            postIDs: postIDs, from: presenter, origin: origin, beneath: beneath, sourceIsComplete: sourceIsComplete
        )
    }

    public func makeSnapFeedViewController(
        postIDs: [PostID],
        ownsInteractiveDismissal: Bool
    ) -> UIViewController {
        snapFeed.makeSnapFeedViewController(postIDs: postIDs, ownsInteractiveDismissal: ownsInteractiveDismissal)
    }

    public func makeSnapFeedViewController(
        postIDs: [PostID],
        ownsInteractiveDismissal: Bool,
        sourceIsComplete: Bool
    ) -> UIViewController {
        snapFeed.makeSnapFeedViewController(
            postIDs: postIDs, ownsInteractiveDismissal: ownsInteractiveDismissal, sourceIsComplete: sourceIsComplete
        )
    }

    public func makePostFeedViewController(for postID: PostID, opensComments: Bool) -> UIViewController {
        snapFeed.makePostFeedViewController(for: postID, opensComments: opensComments)
    }

    // The grids the builder lends: `PostGridsAssembly`.
    public func makePostGridPage(style: PostGridPageStyle, savesPosts: Bool) -> any PostGridPage {
        grids.makePostGridPage(style: style, savesPosts: savesPosts)
    }

    public func makePostSetSurface(style: PostSetSurfaceStyle) -> any PostSetSurface {
        grids.makePostSetSurface(style: style)
    }

    // The plain opening's geometry: `SnapFeedAssembly`.
    public func textRevealGeometry(closing feed: UIViewController, onto origin: TextRevealOrigin) -> RevealGeometry {
        snapFeed.textRevealGeometry(closing: feed, onto: origin)
    }

    public func makeRevealGeometry(
        dismissing feed: UIViewController,
        origin: TextRevealOrigin,
        onWillClose: (() -> Void)?
    ) -> RevealGeometry {
        snapFeed.makeRevealGeometry(dismissing: feed, origin: origin, onWillClose: onWillClose)
    }

    /// A place's posts as its page draws them (#2381: the place page lives in
    /// Place; its posts are still hydrated by the feed, so every post the
    /// feed above holds is a cache hit). See `placeGalleryPosts(_:base:postCounters:)`.
    nonisolated public func placeGalleryPosts(_ ids: [PostID]) async throws -> [GalleryPost] {
        try await Self.placeGalleryPosts(ids, base: repository, postCounters: postCounters)
    }

    /// A place's posts as its page draws them: the feed's hydration (so
    /// every post the feed above holds is a cache hit), then one batched read
    /// of likes and comments.
    ///
    /// ⚠️ THE TIMELINE READ HYDRATES LIKES ONLY, and a count this page never
    /// asked for is a control this page never draws. The COMMENT count stayed
    /// absent, which `PostMetricLabel.set(nil)` renders as a hidden chip — so
    /// one batched read of likes and comments, through the same
    /// `PostCounterReading` the profile gallery uses. Fail-open: a
    /// missing read leaves every count as the timeline gave it.
    nonisolated static func placeGalleryPosts(
        _ ids: [PostID], base: any FeedProviding, postCounters: (any PostCounterReading)?
    ) async throws -> [GalleryPost] {
        let provider = FixedPostsFeedProvider(base: base, ids: ids)
        var members = try await DiscoverRepository(feed: provider).firstPage().posts
        if let postCounters {
            let byPostID = await postCounters.counters(forPostIDs: members.map(\.id.rawValue))
            if !byPostID.isEmpty {
                members = members.map { post in
                    guard let counts = byPostID[post.id.rawValue] else { return post }
                    var decorated = post
                    decorated.reactionCount = counts.likes ?? post.reactionCount
                    decorated.commentCount = counts.comments
                    return decorated
                }
            }
        }
        return members
    }

    // The text post screen: `TextPostAssembly`.
    public func makeTextPostScreen(publisher: any TextPostPublishing) -> UIViewController {
        textPost.makeTextPostScreen(publisher: publisher)
    }

    public func makeTextPostScreen(publisher: any TextPostPublishing, attaching embed: PostEmbed) -> UIViewController {
        textPost.makeTextPostScreen(publisher: publisher, attaching: embed)
    }

    func makeTextPostScreen(
        publisher: any TextPostPublishing, bookmarks: PostBookmarkStore, attaching embed: PostEmbed? = nil,
        showsEmbeds: Bool = PostEmbeds.areDrawn, recordsVoice: Bool = VoicePosts.areDrawn
    ) -> UIViewController {
        textPost.makeTextPostScreen(
            publisher: publisher, bookmarks: bookmarks, attaching: embed,
            showsEmbeds: showsEmbeds, recordsVoice: recordsVoice
        )
    }

}
