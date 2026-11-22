import CoreModels
import CoreNavigation
import CoreNetworking
import CoreStorage
import EntityStore
import FeedInterface
import MediaCore
import MediaPlayback
import PostGrid
import PostSurfaces
import UIKit

/// The grids the builder lends to other features: For You's grid page (a
/// profile's pages, Chat) and the post set surface (Search). Built once by
/// `FeedFeatureBuilder`.
@MainActor
struct PostGridsAssembly {
    private let repository: any FeedProviding
    private let router: any Router
    private let imagePipeline: ImagePipeline
    private let videoPlayback: VideoPlaybackController?
    private let wallet: (any WalletStaking)?
    private let makeWalletSheet: (@MainActor () -> UIViewController)?
    private let entities: any EntityReading & EntityWriting
    private let unavailablePosts: UnavailablePosts
    private let bookmarks: PostBookmarkStore
    private let postCounters: (any PostCounterReading)?
    /// Read as each screen is built, for `balanceWallet`: the guest rule is
    /// written once, on `Dependencies`.
    private let dependencies: FeedFeatureBuilder.Dependencies
    /// The builder's one warm and one author-mark binding (#2002, #2300).
    private let postOpenWarm: PostOpenWarm?
    private let authorMarks: PostAuthorMarks
    private let snapFeed: SnapFeedAssembly
    private let heldPosts: FeedHeldPosts

    init(
        dependencies: FeedFeatureBuilder.Dependencies, postOpenWarm: PostOpenWarm?, authorMarks: PostAuthorMarks,
        snapFeed: SnapFeedAssembly, heldPosts: FeedHeldPosts
    ) {
        repository = dependencies.repository
        router = dependencies.router
        imagePipeline = dependencies.imagePipeline
        videoPlayback = dependencies.videoPlayback
        wallet = dependencies.wallet
        makeWalletSheet = dependencies.makeWalletSheet
        entities = dependencies.entities
        unavailablePosts = dependencies.unavailablePosts
        bookmarks = dependencies.bookmarks
        postCounters = dependencies.postCounters
        self.dependencies = dependencies
        self.postOpenWarm = postOpenWarm
        self.authorMarks = authorMarks
        self.snapFeed = snapFeed
        self.heldPosts = heldPosts
    }

    /// For You's own grid page, for a feature that hosts its own posts — the
    /// profile's pages (#1273, epic #1269): every media tile in the app is
    /// For You's tile. `savesPosts`: whether its cards offer to save (the
    /// viewer's own saved pile); false hides the control.
    ///
    /// The composition root's, on the concrete builder: `FeedFeatureBuilding`
    /// no longer names the page, whose protocol needs PostGrid's cards
    /// (`PostCardStaking`), so FeedInterface stays clear of PostGrid (#2380).
    /// The profile and Chat receive it as a closure.
    public func makePostGridPage(style: PostGridPageStyle, savesPosts: Bool) -> any PostGridPage {
        // The app's one pool, the same instance For You's tabs borrow from.
        let page = PostGridPages.make(
            style: style, imagePipeline: imagePipeline, videoPlayback: videoPlayback,
            bookmarks: savesPosts ? bookmarks : nil, withheldPosts: unavailablePosts,
            postOpenWarm: postOpenWarm
        )
        // A card's author band wears its relation mark (#2300).
        (page as? PostGridPageView)?.authorMarks = authorMarks
        return page
    }

    public func makePostSetSurface(style: PostSetSurfaceStyle) -> any PostSetSurface {
        let base = repository
        let postCounters = postCounters
        let entities = entities
        let surface = PostSetSurfaceViewController(
            style: style,
            imagePipeline: imagePipeline,
            // The app's one pool, the same instance For You's tabs borrow from.
            videoPlayback: videoPlayback,
            bookmarks: bookmarks,
            withheldPosts: unavailablePosts,
            // What the app holds, drawn before the hydration lands (#1863).
            held: { [self] id in heldPosts.heldGalleryPost(id) },
            hydrate: { ids in
                // The place profile's hydration, verbatim in shape: a fixed-set
                // provider through the For You repository so every member is a
                // cache hit, then ONE batched counter read for both counts.
                // Three surfaces asking three different ways is how they come to
                // disagree — see `PlaceFeatureBuilder.makeClusterGallery`'s note (Place).
                let provider = FixedPostsFeedProvider(base: base, ids: ids)
                // A post deleted in this session is no result, whatever the
                // index still answers (#896).
                guard let hydrated = try? await DiscoverRepository(feed: provider).firstPage().posts
                else { return [] }
                let posts = hydrated.filter { !entities.isDeleted($0.id) }
                guard let postCounters else { return posts }
                let byPostID = await postCounters.counters(forPostIDs: posts.map(\.id.rawValue))
                guard !byPostID.isEmpty else { return posts }
                return posts.map { post in
                    guard let counts = byPostID[post.id.rawValue] else { return post }
                    var decorated = post
                    decorated.reactionCount = counts.likes ?? post.reactionCount
                    decorated.commentCount = counts.comments
                    return decorated
                }
            }
        )
        // ⚠️ A FLIGHT, NOT A PUSH, and this is what it used to be:
        // `router.route(to: .post(id))`, the platform's plain slide. These
        // pages ARE the grid For You's two tabs were (until #2453), so a tap on
        // them had every reason to open the way a tap on For You did — and did
        // not, because the host was new and nobody had handed it the opener.
        surface.openPost = { [self] presenter, origin, ids in
            snapFeed.presentSnapFeedHero(postIDs: ids, from: presenter, origin: origin)
        }
        // The results draw their posts' live counts, and their like chips
        // stake from the app's one wallet (#896) — For You's cards' binding.
        let staking = wallet.map { PostCardStaking(wallet: $0, entities: entities, saves: bookmarks) }
        surface.staking = staking
        // …and their author bands wear the relation mark (#2300).
        surface.authorMarks = authorMarks
        // "View all" on a discover page: For You's own media gallery, with the
        // header For You's pushed screens wear (#629).
        surface.makeGallery = { [self] in
            let gallery = DiscoverGalleryViewController(
                imagePipeline: imagePipeline, videoPlayback: videoPlayback,
                bookmarks: bookmarks, withheldPosts: unavailablePosts,
                header: PushedScreenHeader(wallet: dependencies.balanceWallet, makeWalletSheet: makeWalletSheet, router: router),
                // The same binding as the results it was pushed from.
                staking: staking,
                openPost: { [self] presenter, origin, ids in
                    snapFeed.presentSnapFeedHero(postIDs: ids, from: presenter, origin: origin)
                }
            )
            gallery.postOpenWarm = postOpenWarm
            return gallery
        }
        // Its tiles warm their posts' first comments (#2002).
        surface.postOpenWarm = postOpenWarm
        return surface
    }
}
