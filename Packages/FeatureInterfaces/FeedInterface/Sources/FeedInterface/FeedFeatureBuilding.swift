import CoreModels
import CoreNavigation
import UIKit

/// How the post-detail screen presents.
public enum PostDetailMode: Sendable, Equatable {
    /// The full post (header, media, engagement) above its comments — used when
    /// arriving at a post you can't already see (e.g. from a notification).
    case full
    /// Comments + compose bar only, no post header/media — used from the snap
    /// feed, where the post is already full-screen. Text-only snap pages use
    /// this mode too: their engagement is pixel-identical to the media
    /// layouts' (the floating card simply has an empty media slot), so one
    /// mode serves every hosted engagement.
    case commentsOnly
}

/// How the For You tab should present ITSELF in the app's tab bar, given
/// whatever the viewer has the screen set to.
///
/// The tab item is not decoration here — For You is a lens over a corpus, and
/// which lens is active is a mode the viewer chose and can forget they chose.
/// A bar item that still says "For You" with a sparkle while the screen is
/// filtered to Work is the one place that state is invisible, and it is the
/// place someone looks to decide whether to come back.
///
/// Carried as plain data across the interface boundary — a title, an SF Symbol
/// name and a count — so the shell can build a `UITab` from it without
/// importing Feed or knowing that `ContentContext` exists.
public struct ForYouTabPresentation: Equatable, Sendable {
    /// The active lens's name — what the tab item should read.
    public let title: String
    /// The active lens's SF Symbol name, for the item's image.
    public let symbol: String
    /// How much is waiting under that lens. Zero means no badge.
    public let badgeCount: Int

    public init(title: String, symbol: String, badgeCount: Int) {
        self.title = title
        self.symbol = symbol
        self.badgeCount = badgeCount
    }
}

/// A For You root that can hand its content-lens menu to whatever else wants
/// to offer it.
///
/// The screen's own navigation bar carries this menu; the app's tab bar wants
/// the identical one under a long press, so that a viewer who has learned the
/// modes in one place finds the same five rows, the same glyphs and the same
/// counts in the other. Building it twice would be two menus that agree until
/// someone edits one.
///
/// ⚠️ The returned menu resolves its rows AT PRESENTATION, so it can be
/// attached once and left alone — the counts it shows are whatever they are
/// when the long press opens it, not when the shell asked. Rebuilding it on
/// every count change would be a write per page load to a menu nobody has open.
///
/// Choosing a row switches the lens for the whole feature, exactly as choosing
/// it from the screen's own header does: there is one active context, and it
/// does not matter which surface asked.
@MainActor
public protocol ForYouModeMenuProviding: UIViewController {
    func makeModeMenu() -> UIMenu
}

/// Entry point contract for the Feed feature. Other modules (the app shell,
/// or features that embed feed surfaces) depend on this interface package —
/// never on the Feed implementation — so editing Feed internals recompiles
/// nothing but Feed itself.
@MainActor
public protocol FeedFeatureBuilding {
    func makeFeedViewController() -> UIViewController
    /// The For You tab's root: a Discover mosaic and a Following timeline under
    /// one content lens, where tapping a tile opens the full-screen feed seeded
    /// from that page's ordered posts.
    ///
    /// It lives behind the *feed* builder rather than a feature of its own
    /// because the destination it opens (`makeSnapFeedViewController`) and the
    /// read path it shares are both here — one repository, one post cache, so
    /// a tapped tile is already warm in the feed it expands into.
    ///
    /// `onTabPresentationChange` reports how the shell's own bar item should
    /// read — see `ForYouTabPresentation`. It fires on the first load and on
    /// every lens change after it, including while the tab is off screen, which
    /// is the case the bar item exists for.
    func makeForYouViewController(
        onTabPresentationChange: ((ForYouTabPresentation) -> Void)?
    ) -> UIViewController
    /// The detail screen for a single post. `.full` for the `.post` route (e.g.
    /// from a notification); `.commentsOnly` for the `.comments` route (the snap
    /// feed's comment button).
    func makePostDetailViewController(for postID: PostID, mode: PostDetailMode) -> UIViewController
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
    /// Best-effort, cancellable warming of these posts into the shared cache, so
    /// a subsequent `makeSnapFeedViewController` hydrates from memory rather than
    /// the network — used by Maps to prefetch the visible pins on viewport
    /// settle, eliminating the metadata desync on tap. Safe for ids never opened.
    func prewarmPosts(_ ids: [PostID]) async
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
    /// Its argument is WHICH SCREEN IS DEPARTING, and it exists because there
    /// are two of them. The gallery itself is one: it becomes top, the viewer
    /// swipes, and the card flies home carrying the marker's own picture —
    /// `nil`, because a whole grid is not a post and there is nothing to
    /// dissolve. The other is a post pushed OVER the gallery, whose horizontal
    /// swipe escapes past it to the map: that screen is a PAGER, so what the
    /// viewer is leaving is a picture the marker may know nothing about, and
    /// the flight has to dissolve it into the marker's own. Pass the pushed
    /// controller and the source resolves that for itself.
    ///
    /// ⚠️ Still resolved at the DEPARTING screen's own staging, not at its
    /// push. The argument names a screen, never a picture: what that screen is
    /// showing is asked for later, through `SnapFeedSettleReporting`, because
    /// the viewer goes on paging after the caller has stopped watching.
    func makeClusterGallery(
        postIDs: [PostID],
        title: String,
        following: ClusterGalleryFollowing?,
        feed: UIViewController,
        mapReturn: @escaping (UIViewController?) -> (any ZoomTransitionSource)?
    ) -> UIViewController
}

/// The follow-this-place seam a cluster gallery's header renders: the caller
/// (Maps, whose store owns the followed set) hands the gallery the state and
/// the toggle, and the gallery is just a button. Closures rather than a
/// protocol on purpose — the gallery must not know what a place IS, only
/// whether its subject is followed and how to flip that.
public struct ClusterGalleryFollowing {
    /// The current state, read fresh whenever the button renders.
    public let isFollowing: @MainActor () -> Bool
    /// Flips the state, returning the NEW value — what the button shows next.
    public let toggle: @MainActor () -> Bool

    public init(
        isFollowing: @escaping @MainActor () -> Bool,
        toggle: @escaping @MainActor () -> Bool
    ) {
        self.isFollowing = isFollowing
        self.toggle = toggle
    }
}

extension FeedFeatureBuilding {
    /// The ordinary case: a For You tab nobody is listening to.
    public func makeForYouViewController() -> UIViewController {
        makeForYouViewController(onTabPresentationChange: nil)
    }

    /// The overwhelmingly common case: a feed about to be flown to, or handed
    /// a slide of its own. Every existing call site means this, so it stays the
    /// unqualified spelling and only the plain-push caller has to say otherwise.
    public func makeSnapFeedViewController(postIDs: [PostID]) -> UIViewController {
        makeSnapFeedViewController(postIDs: postIDs, ownsInteractiveDismissal: true)
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
    /// rendered cover to give). Nil for a text page, which has no picture.
    var settledCoverImage: UIImage? { get }
}
