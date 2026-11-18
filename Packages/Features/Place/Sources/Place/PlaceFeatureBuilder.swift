import CoreModels
import CoreNavigation
import CoreStorage
import DesignSystem
import EntityStore
import FeedInterface
import MediaCore
import MediaPlayback
import PlaceInterface
import PostGrid
import PostSurfaces
import UIKit

/// The Place feature's entry point (#2381), resolved by the composition root
/// and consumed through `PlaceFeatureBuilding` by Maps and the app shell.
///
/// The place page opens posts in the feed's reader, and its posts are the
/// feed's hydration (so every post the feed above holds is a cache hit):
/// both come from the feed, through its interface and the closure the shell
/// hands in. What a place IS stays the map's (`PlaceIdentity`).
@MainActor
public final class PlaceFeatureBuilder: PlaceFeatureBuilding {
    private let feed: any FeedFeatureBuilding
    private let hydrate: @Sendable ([PostID]) async throws -> [GalleryPost]
    private let placePosts: (any PlacePostsListing)?
    private let imagePipeline: ImagePipeline
    private let videoPlayback: VideoPlaybackController?
    private let wallet: (any WalletStaking)?
    private let makeWalletSheet: (@MainActor () -> UIViewController)?
    private let showsBalance: @MainActor () -> Bool
    private let entities: EntityStore
    private let router: (any Router)?
    private let authorMarks: PostAuthorMarks?
    private let postOpenWarm: PostOpenWarm?
    /// The balance the pushed screens' header wears: only where likes move
    /// (#2336).
    private var balanceWallet: (any WalletStaking)? { showsBalance() ? wallet : nil }

    public init(
        /// The reader the page opens posts in, and the posts the app holds.
        feed: any FeedFeatureBuilding,
        /// The feed's hydration of a set of posts, with their counts.
        hydrate: @escaping @Sendable ([PostID]) async throws -> [GalleryPost],
        /// A place's posts past the map's pins (#643). Nil: a place page shows
        /// the pins it was handed.
        placePosts: (any PlacePostsListing)?,
        imagePipeline: ImagePipeline,
        videoPlayback: VideoPlaybackController?,
        /// The app's one wallet, the same the map's toolbar shows.
        wallet: (any WalletStaking)?,
        makeWalletSheet: (@MainActor () -> UIViewController)?,
        showsBalance: @escaping @MainActor () -> Bool,
        entities: EntityStore,
        router: (any Router)?,
        /// The cards' relation marks (#2300) and the tiles' comment warm-up
        /// (#2002): the feed's own, so a place's cards match every other.
        authorMarks: PostAuthorMarks?,
        postOpenWarm: PostOpenWarm?
    ) {
        self.feed = feed
        self.hydrate = hydrate
        self.placePosts = placePosts
        self.imagePipeline = imagePipeline
        self.videoPlayback = videoPlayback
        self.wallet = wallet
        self.makeWalletSheet = makeWalletSheet
        self.showsBalance = showsBalance
        self.entities = entities
        self.router = router
        self.authorMarks = authorMarks
        self.postOpenWarm = postOpenWarm
    }

    public func makePlacePage(title: String, identity: PlaceIdentity) -> UIViewController {
        placeGallery(
            postIDs: [], title: title, rank: nil, identity: identity, following: nil,
            feed: nil, mapReturn: nil, markerClose: nil
        )
    }

    public func makeClusterGallery(
        postIDs: [PostID],
        title: String,
        rank: PlaceRankBadge?,
        identity: PlaceIdentity?,
        following: ClusterGalleryFollowing?,
        feed: UIViewController,
        mapReturn: @escaping (@escaping () -> UIImage?) -> (any ZoomTransitionSource)?,
        markerClose: ((UIViewController) -> RevealGeometry?)?
    ) -> UIViewController {
        placeGallery(
            postIDs: postIDs, title: title, rank: rank, identity: identity, following: following,
            feed: feed, mapReturn: mapReturn, markerClose: markerClose
        )
    }

    /// The place page, from the map (pins, the feed above it, a way home to
    /// the marker) or alone (a link: none of those).
    private func placeGallery(
        postIDs: [PostID],
        title: String,
        rank: PlaceRankBadge?,
        identity: PlaceIdentity?,
        following: ClusterGalleryFollowing?,
        feed feedPage: UIViewController?,
        mapReturn: ((@escaping () -> UIImage?) -> (any ZoomTransitionSource)?)?,
        markerClose: ((UIViewController) -> RevealGeometry?)?
    ) -> UIViewController {
        let gallery = PlaceProfileViewController(
            postIDs: postIDs,
            placeName: title,
            rank: rank,
            identity: identity,
            imagePipeline: imagePipeline,
            videoPlayback: videoPlayback,
            following: following,
            // The same balance the map's toolbar shows under this page, and
            // the same sheet it opens — one wallet instance app-wide, because
            // `WalletStore`'s change post is scoped to the instance.
            wallet: wallet,
            makeWalletSheet: makeWalletSheet,
            showsBalance: showsBalance(),
            entities: entities,
            // Every member the app already holds, drawn before the hydration
            // (#1863) — all of them or none (`PlaceProfileViewController`).
            heldMembers: Self.allHeld(postIDs.map { feed.heldGalleryPost($0) }),
            loadPosts: { [hydrate] in
                // The feed's hydration, so every member the feed above holds
                // is a cache hit. Unranked: the profile applies its own
                // popularity order (`PlaceProfileViewController.ranked`).
                try await hydrate(postIDs)
            },
            // Past the pins (#643): the place's own pages, hydrated the same way.
            loadMore: identity?.query.flatMap { query in
                placePosts.map { listing in
                    { [hydrate] token in
                        let page = try await listing.placePostIDs(query, after: token)
                        let posts = page.ids.isEmpty
                            ? []
                            : try await hydrate(page.ids)
                        return PlacePostsPage(posts: posts, nextPageToken: page.next)
                    }
                }
            },
            openPost: { [feed] presenter, origin, ids in
                feed.presentSnapFeedHero(postIDs: ids, from: presenter, origin: origin)
            }
        )
        // No `gallery.title`: the place's name lives on the BANNER, in its
        // identity row, and does not dock — a bar title set here would sit at
        // full strength over it.
        gallery.activePostID = { [weak feedPage] in
            (feedPage as? any SnapFeedSettleReporting)?.settledPostID
        }
        // Eager on purpose: the gallery lives its early life invisible under
        // the feed (a mid-stack insertion never loads its view), and the
        // first anyone sees of it is a dismissal LANDING on it.
        gallery.beginLoading()
        // The page's own way home — staged when it becomes top
        // (`installMapReturnIfTop`): hero to the marker, slide as fallback.
        gallery.mapReturn = mapReturn
        gallery.markerClose = markerClose
        // A close down onto one of its text cards is the reader's own reveal.
        gallery.revealGeometry = { [feed] page, origin in
            feed.textRevealGeometry(closing: page, onto: origin)
        }
        // The cards' author bands wear the relation mark (#2300).
        gallery.authorMarks = authorMarks
        // The titles' pushes — For You's own pushed screens, with the header
        // they wear there (`PushedScreenHeader`).
        let staking = wallet.map { PostCardStaking(wallet: $0, entities: entities) }
        let openHero: (UIViewController, SnapFeedHeroOrigin, [PostID]) -> Void = { [feed] presenter, origin, ids in
            feed.presentSnapFeedHero(postIDs: ids, from: presenter, origin: origin)
        }
        gallery.makePostList = { [self] in
            let list = PushedPostListViewController(
                kind: .popular, imagePipeline: imagePipeline, videoPlayback: videoPlayback,
                staking: staking,
                header: PushedScreenHeader(wallet: balanceWallet, makeWalletSheet: makeWalletSheet, router: router),
                openPost: openHero
            )
            list.postOpenWarm = postOpenWarm
            list.authorMarks = authorMarks
            return list
        }
        gallery.makeGallery = { [self] in
            let pushed = DiscoverGalleryViewController(
                imagePipeline: imagePipeline, videoPlayback: videoPlayback,
                header: PushedScreenHeader(wallet: balanceWallet, makeWalletSheet: makeWalletSheet, router: router),
                staking: staking,
                openPost: openHero
            )
            pushed.postOpenWarm = postOpenWarm
            return pushed
        }
        // A place's tiles, and a cluster's, warm their posts' first comments
        // (#2002).
        gallery.postOpenWarm = postOpenWarm
        return gallery
    }

    /// Every post, or none: a place's corpus drawn from what is held only
    /// when it is whole (#1863). Pure.
    nonisolated static func allHeld(_ posts: [GalleryPost?]) -> [GalleryPost] {
        let held = posts.compactMap { $0 }
        return held.count == posts.count ? held : []
    }
}
