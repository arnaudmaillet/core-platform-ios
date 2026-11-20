import CoreModels
import CoreNavigation
import PostGridSeam
import Transitions
import UIKit

/// Entry point contract for the Feed feature. Other modules (the app shell,
/// or features that embed feed surfaces) depend on this interface package —
/// never on the Feed implementation — so editing Feed internals recompiles
/// nothing but Feed itself.
///
/// It refines `TextPostScreenBuilding` so the shell hands the Upload builder
/// this very value and the relationship is checked by the compiler: the "+"
/// menu's Text Post is a text post's own page, so Feed draws it, and Upload
/// owns the publishing. (The conversation, drawn from the same pieces, is
/// Chat's own screen since #2380.)
@MainActor
public protocol FeedFeatureBuilding: TextPostScreenBuilding {
    func makeFeedViewController() -> UIViewController
    /// ONE POST SCREEN (#1577, the owner 2026-10-22): the vertical full-screen
    /// feed on `postID`, its comments up when `opensComments` — what the
    /// `.post` and `.comments` routes push (a tapped push notification,
    /// `-open-post`). A plain push with no flight: the platform's own edge pop
    /// dismisses it (`ownsInteractiveDismissal: false`, the `.postStream`
    /// route's reason).
    func makePostFeedViewController(for postID: PostID, opensComments: Bool) -> UIViewController
    /// A full-screen snap feed seeded with a fixed, ordered set of posts rather
    /// than the following timeline — the surface a Maps pin/cluster tap expands
    /// into. Reuses the entire snap feed (video pool, likes, comments, active-
    /// cell lifecycle); only the data source differs. The returned VC conforms
    /// to `ZoomTransitionDestination` so a hero transition can drive it.
    ///
    /// `ownsInteractiveDismissal` answers the one question a caller cannot
    /// delegate: whether it is going to put a dismissal gesture on this screen
    /// itself. `true` (the default, via the convenience overload below) means a
    /// flight or a slide is about to be attached, and the stack's native edge
    /// pop must stay out of its way. `false` means this is an ordinary push
    /// with nothing custom behind it, so the platform's own gesture applies.
    ///
    /// ⚠️ It is a parameter rather than a property the caller sets afterwards
    /// because the property lives on a concrete type the interface deliberately
    /// hides. A caller outside the Feed package could claim ownership only by
    /// accident — by inheriting the default — and had no way at all to
    /// disclaim it. That asymmetry is precisely how a pushed feed ended up
    /// refusing the native pop while attaching nothing of its own: a screen
    /// with no way back but the chevron.
    func makeSnapFeedViewController(
        postIDs: [PostID],
        ownsInteractiveDismissal: Bool
    ) -> UIViewController

    /// The same feed over a COMPLETE set (#628): `postIDs` is everything its
    /// source has — a map marker's or cluster's posts — so a swipe up past the
    /// last one may close the feed. Without this a feed never knows it is at
    /// the end, which is the safe answer for a window cut from a longer grid.
    func makeSnapFeedViewController(
        postIDs: [PostID],
        ownsInteractiveDismissal: Bool,
        sourceIsComplete: Bool
    ) -> UIViewController
    // (see `SnapFeedSettleReporting` below for asking a built feed where the
    // viewer stopped — the one question a presenter outside this package has
    // to be able to put to it.)
    /// Pushes that same feed onto `presenter`'s stack with a HERO flight from
    /// `origin`, instead of a standard slide.
    ///
    /// Here rather than in each feature because the flying card is the feed's
    /// own view and the transition is wired to it. A caller describes where the
    /// post is on screen (`SnapFeedHeroOrigin`) and gets the same flight the
    /// For You grid has; it never sees a card, a source, or a transition
    /// controller. The returned value is nothing — the transition owns its own
    /// lifetime and releases when the viewer comes back.
    func presentSnapFeedHero(
        postIDs: [PostID],
        from presenter: UIViewController,
        origin: SnapFeedHeroOrigin
    )
    /// Pushes that same feed onto `presenter`'s stack with the PLATFORM's own
    /// slide — no flight, no card, no origin.
    ///
    /// The presentation a post with nothing to fly gets. `presentSnapFeedHero`
    /// already degrades to exactly this when its origin reports `hasHero ==
    /// false`; this is the same destination for a caller that has no origin to
    /// describe in the first place — a Maps text pin knows only post ids, and
    /// inventing a `SnapFeedHeroOrigin` whose every flight-shaped field is
    /// ignored would be data that isn't.
    ///
    /// Not merely `nav.pushViewController`: the pushed feed refuses the stack's
    /// native edge pop (it carries a custom leading item and claims its own
    /// dismissal), so the slide gesture has to be attached and retained with
    /// it. That is the whole reason this lives behind the interface instead of
    /// at each call site — see `PlainPushDismissalTests` for the screen a
    /// hand-rolled push leaves behind: perfect pixels, no way back but the
    /// chevron.
    func pushSnapFeed(postIDs: [PostID], from presenter: UIViewController)
    /// The same push over a COMPLETE set (#674): the posts are everything the
    /// source has — a map marker's — so the feed's last post is the end and a
    /// swipe up there grabs the window (#628).
    func pushSnapFeed(postIDs: [PostID], from presenter: UIViewController, sourceIsComplete: Bool)
    /// The same push with a page BENEATH the feed (#2015): what a downward
    /// dismissal lands on — a city's or a country's place page, for a map
    /// marker that opens with the plain push. The rightward close is the
    /// platform's slide, back to the presenter.
    func pushSnapFeed(
        postIDs: [PostID], from presenter: UIViewController, sourceIsComplete: Bool,
        beneath: ((UIViewController) -> UIViewController)?
    )
    /// The same push, opened as a WINDOW growing out of `origin` rather than as
    /// a slide from the edge.
    ///
    /// Separate from `presentSnapFeedHero` because that one's origin is built
    /// around a flying card — it needs the `GalleryPost` and the stream behind
    /// it to draw one — and a caller here has neither. A map's marker knows a
    /// coordinate, a tint and some post ids; asked for a post model it would
    /// have to invent one, which is the objection `pushSnapFeed` was written
    /// against and it applies just as much to its window-shaped sibling.
    ///
    /// What this takes is exactly what the reveal reads: where the source is,
    /// what shape and colour it is, and what to draw in the window at each end.
    ///
    /// `beneath` builds the screen a VERTICAL dismissal of this feed lands on
    /// — the place page a city/country cluster must always offer, whatever
    /// face its marker wears. Handed the freshly built feed (the page's grid
    /// tracks the feed's active post) and slid under it at dismissal-begin,
    /// never pushed: the horizontal close and the back button keep landing on
    /// `presenter`, window-shaped, exactly as they do with `nil`.
    func revealSnapFeed(
        postIDs: [PostID],
        from presenter: UIViewController,
        origin: TextRevealOrigin,
        beneath: ((UIViewController) -> UIViewController)?
    )
    /// The same window over a COMPLETE set (#674) — see
    /// `pushSnapFeed(postIDs:from:sourceIsComplete:)`.
    func revealSnapFeed(
        postIDs: [PostID],
        from presenter: UIViewController,
        origin: TextRevealOrigin,
        beneath: ((UIViewController) -> UIViewController)?,
        sourceIsComplete: Bool
    )
    /// The same window, built for the CLOSE and pushing nothing.
    ///
    /// Asked at dismissal staging, for a pop whose destination is the surface
    /// that owns `origin` — so a screen opened by a hero can still close as a
    /// window onto the thing it came from, which is what a post with no media
    /// left to fly needs.
    ///
    /// `onWillClose` is the tap's equivalent of a drag's `onWillBeginPop`: a
    /// chevron has no "begin", and chrome restored for the return only paints
    /// when it is restored OUTSIDE the transition.
    func makeRevealGeometry(
        dismissing feed: UIViewController,
        origin: TextRevealOrigin,
        onWillClose: (() -> Void)?
    ) -> RevealGeometry
    /// Best-effort, cancellable warming of these posts into the shared cache, so
    /// a subsequent `makeSnapFeedViewController` hydrates from memory rather than
    /// the network — used by Maps to prefetch the visible pins on viewport
    /// settle, eliminating the metadata desync on tap. Safe for ids never opened.
    func prewarmPosts(_ ids: [PostID]) async
    /// Starts `postID`'s page player NOW, at `seconds` into its clip, because a
    /// finger has landed on that post's map marker (#646): when the post opens,
    /// its page joins the running player and has a frame at once. Nil when
    /// there is nothing to warm. The caller ends it — see `FeedPlaybackWarm`.
    ///
    /// ⚠️ A REQUIREMENT, read through `any FeedFeatureBuilding`; the default
    /// warms nothing.
    func warmPlayback(of postID: PostID, at seconds: TimeInterval?) -> (any FeedPlaybackWarm)?
    /// Like `warmPlayback`, but the player plays to its first frame and
    /// PAUSES there (#654): the map prerolls the one marker nearest its centre
    /// while it is idle, and `FeedPlaybackWarm.resume(at:)` plays it on when
    /// that marker is touched. Nil when the device should not spend it — Low
    /// Power, thermal pressure, preloading off — or there is nothing to warm.
    ///
    /// ⚠️ A REQUIREMENT, like `warmPlayback`; the default prerolls nothing.
    func prerollPlayback(of postID: PostID, at seconds: TimeInterval?) -> (any FeedPlaybackWarm)?
    /// Builds the place gallery that sits BENEATH a semantic-cluster feed
    /// (city/country/region — the cluster-gallery milestone's Case B): a grid
    /// of the cluster's members ranked by engagement, titled `title`
    /// ("Paris • City Cluster"), with its hydration already started so the
    /// first dismissal into it lands on tiles rather than a skeleton.
    ///
    /// `feed` is the snap feed ABOUT to be pushed over it (built by
    /// `makeSnapFeedViewController` from the same ids): the gallery watches
    /// its active post so a dismissal lands on the tile of the post the
    /// viewer actually left, and the wiring between the two is Feed-internal.
    ///
    /// The returned controller is an ordinary navigation citizen (tab bar
    /// visible, native pop back) that ALSO conforms to CoreNavigation's
    /// `ZoomTransitionSource` — the caller registers it as the flight target
    /// for pops that land on it. Tapping a tile opens that post over the
    /// gallery with the standard hero pair.
    ///
    /// `following` puts the follow-this-place toggle in the gallery's header
    /// (`nil` hides it — a caller whose subject has no followable identity).
    ///
    /// `mapReturn` stages a dismissal back to the map: it produces a fresh
    /// flight source for the cluster's marker — fresh because the marker's
    /// face, ring and even presence can all have changed since the tap — with
    /// the plain slide kept as the fallback whenever it answers `nil` (the
    /// marker left the map).
    ///
    /// Called when the gallery becomes the top screen — the ONE departure it
    /// has, now that a post pushed over it goes home to its own tile rather
    /// than escaping past it to the map.
    ///
    /// `departureStill` is what that screen LOOKS LIKE, asked when the flight
    /// stages and never before. Without it the card wears the marker's own face
    /// from the first frame — a whole page collapsing straight into an icon,
    /// with nothing of what was on screen carried across. The closure returning
    /// nil leaves exactly that behaviour, which is the honest floor for a
    /// screen that cannot draw itself.
    ///
    /// ⚠️ A PICTURE, not a post. The departing screen here is a GRID: there is
    /// no single post leaving, which is why this is a still and not an id the
    /// way every other departure on this seam is.
    /// A surface showing an arbitrary SET of posts, in the caller's order.
    ///
    /// The two styles are the two For You tabs — cards and a media grid — which
    /// are one component in this app, so this is one method with a parameter.
    ///
    /// ⚠️ IDS IN, HYDRATION INSIDE. The caller has ids and nothing else; Feed
    /// owns the only path in this repo that turns a bare `[PostID]` into
    /// complete posts (a fixed-set provider through the For You repository,
    /// plus one batched counter read). A caller holding search hits could not
    /// draw a card from them: a `search.v1` hit carries an author, a thumbnail
    /// key and a date, and no caption, attachments, aspect ratio or counts.
    ///
    /// ⚠️ NO VIDEO PLAYBACK IS ATTACHED. The player pool is app-wide and its
    /// budget is already the tightest thing in the hero suite; a surface that
    /// is one tab of a pushed screen is not where the remaining loans should
    /// go. Posts render their posters here.
    func makePostSetSurface(style: PostSetSurfaceStyle) -> any PostSetSurface

    /// The posts behind `ids`, for a surface that lists posts by id without
    /// being a feed — the wallet's stakes. Cached entries answer at once; the
    /// rest are fetched together. A post that cannot be loaded is simply
    /// absent from the answer.
    ///
    /// As GRID posts — For You's own projection — because the surface also
    /// flies them into the feed (`presentSnapFeedHero` takes a `GalleryPost`),
    /// and a row drawn from one model and flown as another is how a card and
    /// its page come to disagree.
    func galleryPosts(_ ids: [PostID]) async -> [PostID: GalleryPost]

    /// The post as the app already holds it, read synchronously (#1862): the
    /// feed's cache, then the app's store. Nil when neither holds it — the
    /// caller then opens without waiting, onto the feed's own loading page.
    @MainActor
    func heldGalleryPost(_ id: PostID) -> GalleryPost?

    /// The reveal that closes `feed` (a reader this builder made) down onto
    /// a text card at `origin`, on a page beneath it: the place page's
    /// Popular card (#2381). The feed's own reveal — its veil, its author
    /// band and its caption anchor — so every such close is the same.
    func textRevealGeometry(closing feed: UIViewController, onto origin: TextRevealOrigin) -> RevealGeometry
}

/// A post's page player started ahead of its open (#646).
@MainActor
public protocol FeedPlaybackWarm: AnyObject {
    /// Lets go. `opened`: the post opened, and its page is joining the player.
    /// Anything else stops it and leaves no resume position behind.
    func end(opened: Bool)
    /// Whether the player has decoded a picture yet — what decides that a
    /// flight can carry it from its first frame.
    var hasPicture: Bool { get }
    /// Puts the player's picture on `surface` too — a flight card's own render
    /// surface — the way a grid tile's live player rides its flight. False
    /// when the surface is not one the player can draw on.
    func mirror(onto surface: UIView) -> Bool
    /// Plays a prerolled (paused) player on, from `seconds` into its clip when
    /// given — the moment the marker shows now (#654). On a playing one it only
    /// moves the playhead.
    func resume(at seconds: TimeInterval?)
}

extension FeedFeatureBuilding {
    /// A builder that holds nothing synchronously answers nil.
    @MainActor
    public func heldGalleryPost(_ id: PostID) -> GalleryPost? { nil }

    public func warmPlayback(of postID: PostID, at seconds: TimeInterval?) -> (any FeedPlaybackWarm)? { nil }
    public func prerollPlayback(of postID: PostID, at seconds: TimeInterval?) -> (any FeedPlaybackWarm)? { nil }
}

/// A post surface once made: a view controller, and a way to tell it what to
/// show. See `FeedFeatureBuilding.makePostSetSurface(style:)`.
@MainActor
public protocol PostSetSurface: AnyObject {
    var viewController: UIViewController { get }
    func show(_ state: PostSetSurfaceState)

    /// Whether this surface is the one the viewer is looking at.
    ///
    /// ⚠️ THE CALLER OWNS THIS, and it is not the same question as "is my view
    /// in a window". A surface can be laid out, loaded and one swipe away
    /// while another is on screen — which is exactly what a pager does — and a
    /// surface that started playing on being loaded would have two or three
    /// grids borrowing players for tabs nobody is reading. The host knows which
    /// page is active; the surface cannot.
    func setPlaybackActive(_ active: Bool)

    /// Called as the viewer nears the end of what is shown: the caller's cue
    /// to fetch its next page and show the longer list (#579). A list that
    /// EXTENDS the one on screen is appended — only the new posts are
    /// hydrated, and nothing already shown moves. Nil: the set is whole.
    var onNearEnd: (() -> Void)? { get set }

    /// The failed state's Try Again was pressed — the caller's cue to ask
    /// again for what failed (#798). Also what a pull on the surface reports:
    /// the caller decides whether there is anything to ask again for. Nil: the
    /// surface has no one to retry for.
    var onRetry: (() -> Void)? { get set }

    /// The footer spinner, while the caller fetches its next page.
    func setPaging(_ paging: Bool)

    /// Whether the caller has another page past what it showed — what lets a
    /// full-screen feed opened from a tile go on into it, and know when to
    /// stop (#638). Set it with every answer; false until said otherwise.
    func setHasMore(_ hasMore: Bool)

    /// `.discover` only (#629): a row of cards above the list — For You's
    /// "Following" slot — showing these posts in this order. Anything but
    /// `.posts` (or an empty one) shows no row. `hasMore`: the list its title
    /// opens holds more than these posts, so the row ends on "View all"
    /// (#1671) — without it, only a row cut at its limit does.
    func showLeadRow(_ state: PostSetSurfaceState, hasMore: Bool)
    /// `.discover` only: what the lead row and the list are titled — For You's
    /// "Following" and "For you".
    func setSectionTitles(row: String, list: String)
    /// `.discover` only: the lead row's title was tapped — the host's cue to
    /// push the row's whole list.
    var onLeadRowTitleTapped: (() -> Void)? { get set }
}

public extension PostSetSurface {
    var onNearEnd: (() -> Void)? {
        get { nil }
        set {}
    }

    var onRetry: (() -> Void)? {
        get { nil }
        set {}
    }

    func setPaging(_ paging: Bool) {}
    func setHasMore(_ hasMore: Bool) {}
    func showLeadRow(_ state: PostSetSurfaceState, hasMore: Bool) {}
    func setSectionTitles(row: String, list: String) {}
    var onLeadRowTitleTapped: (() -> Void)? {
        get { nil }
        set {}
    }
}

/// Which For You shape the caller wants.
public enum PostSetSurfaceStyle: Sendable {
    /// Full-width cards — For You's "Following".
    case cards
    /// A media grid — For You's "View all" mosaic.
    case gallery
    /// For You's own page (#629): cards with slices of the media mosaic
    /// between them, "View all" on each slice pushing the media gallery, and
    /// an optional row of cards above it (`showLeadRow`).
    case discover
}

/// What a post surface is being asked to show.
public enum PostSetSurfaceState: Equatable, Sendable {
    case loading
    /// ⚠️ THE ORDER IS THE CALLER'S ANSWER, not a suggestion. A surface that
    /// re-ranked what it was handed would show something other than what the
    /// caller's own sort produced, under the caller's own label.
    case posts([PostID])
    case empty(message: String)
    case failed(message: String)
}

extension FeedFeatureBuilding {
    /// The overwhelmingly common case: a feed about to be flown to, or handed
    /// a slide of its own. Every existing call site means this, so it stays the
    /// unqualified spelling and only the plain-push caller has to say otherwise.
    public func makeSnapFeedViewController(postIDs: [PostID]) -> UIViewController {
        makeSnapFeedViewController(postIDs: postIDs, ownsInteractiveDismissal: true)
    }

    /// A conformer that cannot tell a complete set from a window opens the
    /// plain feed — "not known to be the end", the safe answer.
    public func makeSnapFeedViewController(
        postIDs: [PostID], ownsInteractiveDismissal: Bool, sourceIsComplete: Bool
    ) -> UIViewController {
        makeSnapFeedViewController(postIDs: postIDs, ownsInteractiveDismissal: ownsInteractiveDismissal)
    }

    /// The same safe answer for the plain push.
    public func pushSnapFeed(postIDs: [PostID], from presenter: UIViewController, sourceIsComplete: Bool) {
        pushSnapFeed(postIDs: postIDs, from: presenter)
    }

    /// …and with a page beneath: none, the plain push.
    public func pushSnapFeed(
        postIDs: [PostID], from presenter: UIViewController, sourceIsComplete: Bool,
        beneath: ((UIViewController) -> UIViewController)?
    ) {
        pushSnapFeed(postIDs: postIDs, from: presenter, sourceIsComplete: sourceIsComplete)
    }

    /// And for the window.
    public func revealSnapFeed(
        postIDs: [PostID],
        from presenter: UIViewController,
        origin: TextRevealOrigin,
        beneath: ((UIViewController) -> UIViewController)?,
        sourceIsComplete: Bool
    ) {
        revealSnapFeed(postIDs: postIDs, from: presenter, origin: origin, beneath: beneath)
    }
}

/// A pushed feed, asked where the viewer actually stopped.
///
/// The feed is a PAGER, and every transition a presenter stages was decided
/// when the post was OPENED. A presenter outside this package — the map,
/// staging a flight home to its marker — has no other way to learn that the
/// viewer swiped on, and staging the close against the post that was tapped
/// is how a card ends up flying a photograph the viewer has not seen for
/// several pages.
///
/// Deliberately one property and no more: the answer is needed at dismissal
/// STAGING, so a caller reads it inside the hook that stages, never captures
/// it. The seam exists because the concrete feed type is one this interface
/// hides on purpose.
@MainActor
public protocol SnapFeedSettleReporting: AnyObject {
    /// The post whose page is settled, or nil before the first settle.
    var settledPostID: PostID? { get }
    /// The still that page is drawing — the picture a flight home has to
    /// dissolve away when it is landing somewhere else.
    ///
    /// From the FEED rather than from the presenter's own thumbnail of the same
    /// post, and the difference is visible twice over: a carousel post is
    /// showing one of several pictures and only the page knows which, and a
    /// presenter's copy may not exist at all (an off-screen row has no
    /// rendered cover to give). Nil for a text page, which has no picture — and
    /// for a text page alone: a video answers with its current frame.
    var settledCoverImage: UIImage? { get }
    /// The page of a collection the settled post is showing, 0-based; nil for
    /// a single picture (#1326). A close from page N of the post a source
    /// opened from must still LEAVE on page N: the source's own cover is the
    /// collection's head.
    var settledMediaPage: Int? { get }
}

public extension SnapFeedSettleReporting {
    var settledMediaPage: Int? { nil }
}
