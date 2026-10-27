import CoreModels
import CoreNavigation
import CoreStorage
import DesignSystem
import EntityStore
import FeedInterface
import HeroPage
import MediaCore
import MediaPlayback
import PostGrid
import ShareSheet
import UIKit

/// The PLACE PROFILE that sits BENEATH a semantic-cluster feed (Case B of the
/// cluster-gallery milestone, redesigned to read like a profile page):
/// tapping a City/Country/Region cluster on the map lands on the snap feed
/// with this screen already on the stack under it, and a downward grab on the
/// feed closes the active post onto the FIRST ROW of its Activity tab here —
/// whatever kind of post the marker wore and whatever post is on screen.
///
/// The page is a PROFILE's (the hero page, #1656 — the owner 2026-10-23):
/// - a band card wearing the place's TOP media post (highest engagement — the
///   same ranking the Gallery leads with, so banner, pin face and first tile
///   are one post) — or, with none, exactly what a bannerless profile shows;
/// - the flag where a profile's avatar stands, the name over its region, and
///   two counters: the place's RANKING, when it has one, and its aggregated
///   LIKES — likes, not views (product call, 2026-09-30). No bio, no edit —
///   a place is not an account;
/// - ONE page under the metrics, For You's own layout (the owner,
///   2026-10-16 — the Activity/Discover pair and its strip are gone): a
///   **Popular** row of cards (For You's Following row — the place's most
///   liked posts), then **Recent** (For You's list — cards with mosaic
///   stretches and their "View all", ordered by a light For You rule rather
///   than strictly by date: `recent`). Each title pushes its screen.
/// Under the identity, the profile's tray: Pin (follow the place) and its QR
/// code; the balance keeps the top-right slot.
///
/// It remains an ordinary navigation citizen — plain title ("Paris • City
/// Cluster"), tab bar visible, native edge-pop back to the map — because
/// every special behaviour of the flow lives in the TRANSITIONS, not in the
/// screen: the two-VC stack insertion is the map's, the vertical close is
/// the card close's, and this type only has to host its column and say where
/// that close lands (`CardCloseLanding`).
final class PlaceProfileViewController: HeroPageViewController<PlaceProfileTab> {
    /// The page: For You's own list (`.discover` — cards and mosaic
    /// stretches) over the place's posts in the `recent` order, led by
    /// `lead`, and the landing of every dismissal from the map. Not a
    /// bespoke list: a place's activity is posts, and a viewer who reads them
    /// as For You's cards must read them as the same cards here.
    private let activityPage: ForYouGridPage
    /// The list's leading header (#1271): a shelf of posts — "Popular" here —
    /// and the list's title, "Recent", under it (the hashtag page's
    /// arrangement, `PostSetSurfaceViewController`).
    private let shelf: PostShelfSection
    private let lead: GridLeadStack
    /// How many of the place's most liked posts the Popular row carries.
    static let popularRowCount = 10
    /// Pushes the Popular row's whole list, and "Recent"/"View all"'s media
    /// gallery — made by the builder, which holds what their headers need.
    /// Nil: the titles open nothing (a test's page).
    var makePostList: (() -> ForYouPostListViewController)?
    var makeGallery: (() -> DiscoverGalleryViewController)?

    /// The place's flag, where a profile's avatar stands (`HeroHeaderAvatar
    /// .custom`) — a city's is its country's; a neutral disc without one.
    private let flagView: UIImageView
    /// What the header shows: the name over the region, the Ranking and the
    /// Likes, the banner's picture — re-applied whenever one of them moves.
    private var headerContent: HeroHeaderContent
    /// The heart every tile of this page counts, summed — what the Likes
    /// column shows. It used to sit beside a "Views" total and be called
    /// "Reactions"; the views went (2026-09-30).
    private var likesTotal: Int64 = 0


    /// The place's display title ("Paris • City Cluster") — worn as the HERO
    /// TITLE on the banner, and nowhere else.
    ///
    /// ⚠️ THE NAME DOES NOT DOCK, and that is a consequence rather than a
    /// preference. A leading selector had to overwrite `titleView` with a
    /// zero-sized view: a nil or sized title keeps a central reservation that
    /// collapses the leading group into a `•••` below 440pt. So the docked
    /// name and the docked selector cannot both exist, and the profile screen
    /// faced the identical choice and made the identical call — once the
    /// selector docks, a name up there is competing with the one control the
    /// chrome exists to hold.
    private let placeName: String
    /// Whether Popular had posts last time (#1773, `SectionPresenceStore`).
    private let presence: SectionPresenceStore
    /// The page's presence key: the place's name, nil when it has none.
    private var presenceScreen: String? { placeName.isEmpty ? nil : "place.\(placeName)" }
    private let rank: PlaceRankBadge?
    /// ⚠️ THE KIND LINE WAS DELETED, not hidden. "CITY CLUSTER" whispered
    /// above the name was a taxonomy label competing with the identity — and
    /// the map the viewer just came from had already said which kind of
    /// cluster this is. The SPLITTER stays: `placeName` still arrives as the
    /// gallery's "Paris • City Cluster", so stripping the kind is the only way
    /// to draw the name alone (`heroTitleComponents`).
    /// The horizontal scrollers a grab froze — the posts' carousels and the
    /// Popular shelf — with what each was before, to put back (#1595).
    private var grabFrozenScrollers: [GrabFrozenScroller] = []
    /// The page the header rides: the only one (`heroPager`'s).
    private var hostedPages: [ForYouGridPage] { [activityPage] }
    private let activeIndex = 0

    private let postIDs: [PostID]
    private let imagePipeline: ImagePipeline
    private let loadPosts: () async throws -> [GalleryPost]

    // MARK: The place's posts past the pins (#643)

    /// The place's next page — geo_discovery.v1 `ListPlacePosts`, past the
    /// map's pins. Nil: the pins are the whole page, as before.
    private let loadMore: ((String?) async throws -> PlacePostsPage)?
    /// Opened with no pins — a shared place link (#985): its first posts are
    /// the place's first page.
    private var opensAlone: Bool { postIDs.isEmpty }
    private var hasAppeared = false
    /// The posts those pages brought, in the server's order, after the
    /// ranked pins: appended, so no tile on screen ever moves for one.
    private var extraPosts: [GalleryPost] = []
    private enum MoreCursor: Equatable { case start, token(String), exhausted }
    private var moreCursor: MoreCursor = .start
    private var moreLoad: Task<Void, Never>?
    /// Pages in a row that brought nothing new (a POPULAR page re-reads the
    /// ranking and can repeat): this many are walked before waiting for the
    /// next approach.
    private var emptyPagesInARow = 0
    static let maxEmptyPagesInARow = 5
    /// The grid a feed was opened from, whose order its continuation follows.
    private weak var continuationGrid: ForYouGridPage?
    private lazy var feedContinuation = GridFeedContinuation(
        ids: { [weak self] in self?.continuationGrid?.posts.map(\.id) ?? [] },
        hasMore: { [weak self] in self?.hasMorePosts ?? false },
        askMore: { [weak self] in self?.loadMorePosts() }
    )
    /// Whether the place has posts past those shown.
    private var hasMorePosts: Bool { loadMore != nil && moreCursor != .exhausted }
    /// Opens a tapped tile's post over this profile — wired by the builder to
    /// `presentSnapFeedHero`, so a tile-opened post gets the full hero pair
    /// (flight up, grab back to this very tile) with no new machinery.
    private let openPost: (UIViewController, SnapFeedHeroOrigin, [PostID]) -> Void

    /// The post the OVERLYING feed is currently showing — the landing anchor
    /// for a dismissal into this screen. Injected (weakly, by the builder)
    /// so this screen never has to know what a feed is.
    var activePostID: (() -> PostID?)?

    /// The header's follow-this-place toggle, when the caller's subject has a
    /// followable identity (`ClusterGalleryFollowing`); nil hides the button.
    private let following: ClusterGalleryFollowing?
    /// The bar's one trailing item: the balance, when there is a wallet. The
    /// star and the QR code moved back under the identity (#1598).
    private var walletItem: UIBarButtonItem?
    // The row under the identity — the header's action row, the profile's
    // tray for a place (#1598, the owner 2026-10-22): `[Add Pin to Map]
    // [star] [QR code]`, each shown only with its seam (`configureActionRow`).
    /// Pins the place to the map's dock (`dockPin`): a pill there, a tap
    /// flies the map back here.
    private let dockPinButton = AppButton(
        aspect: .pill(.quiet), size: .header, content: PlaceProfileViewController.dockPinContent(docked: false)
    )
    /// Follows the place — as the map's "pinned" filter reads it: the outline
    /// star, filled in its gold (`SaveStar`) once followed.
    private let starButton = AppIconButton(style: .bubble(.quiet), content: .symbol(SaveStar.symbol(saved: false)))
    /// The place's share link as a QR code.
    private let qrButton = AppIconButton(style: .bubble(.quiet), content: .symbol("qrcode"))
    /// The map dock's pin for this place; nil, no pin capsule.
    private let dockPin: ClusterGalleryFollowing?
    private var isDocked = false
    /// What the QR code carries; nil, no bubble.
    private let shareURL: URL?
    /// The viewer's spendable balance, in the same face it wears on the map,
    /// For You, the profile and the post screen.
    private let walletBadge = WalletBadgeButton()
    private let wallet: WalletStore?
    /// Whether the bar wears the balance: not for a guest (#1146). The wallet
    /// still backs the cards' likes.
    private let showsBalance: Bool
    /// Vends the wallet/claim sheet the badge presents — shell-owned, because
    /// it is the same sheet every other badge opens and the five must never
    /// diverge. Nil leaves the badge display-only.
    private let makeWalletSheet: (@MainActor () -> UIViewController)?
    /// Held in a bag rather than a property: a main-actor screen's `deinit`
    /// is nonisolated and may not even read one to unregister it.
    private let walletObservers = NotificationObserverBag()
    /// The follow state as last rendered, so the dock hand-over can redraw
    /// the button without asking the caller's store again.
    private var followState = false

    /// The Activity row a dismissal from the map lands on. Starts at the
    /// cluster's representative (the feed's first post) and re-points to the
    /// post the viewer was on once a close stages it at the head of the list.
    private var anchorID: PostID
    private var loadTask: Task<Void, Never>?
    /// A hydration is in flight — what coalesces a pull (`refresh`).
    private var isLoading = false
    /// The members last fanned out to the page — what a refresh compares its
    /// answer against. Nil until a hydration has landed.
    private var renderedMembers: [GalleryPost]?
    /// How many hydrations actually reached the page.
    private var renders = 0

    // MARK: - The map return flight

    /// Produces a FRESH flight source for the cluster marker this page
    /// belongs to — assigned by the builder
    /// (`FeedFeatureBuilding.makeClusterGallery`), resolved lazily because
    /// the marker's face, ring and presence can all churn while this page is
    /// buried under the feed. `nil` — or a `nil` answer — keeps the plain
    /// slide: the fallback dismissal for a marker the map no longer shows.
    /// The map's way home — see `FeedFeatureBuilding.makeClusterGallery`.
    /// This page is the only screen that leaves for the map: a post opened
    /// from it goes home to its own tile on both axes.
    ///
    /// Handed a closure that draws this page, so the flight can dissolve what
    /// is on screen into the marker's face instead of cutting to it.
    var mapReturn: ((@escaping () -> UIImage?) -> (any ZoomTransitionSource)?)?

    /// The map's way home as a WINDOW onto the marker (Maps'
    /// `makeMarkerClose`) — preferred over `mapReturn` whenever it is set.
    ///
    /// ⚠️ The hero return flew the MARKER's face: under a grab this page was
    /// hidden and a marker-shaped sliver of it rode the finger over black.
    /// The window keeps the page itself under the finger and closes onto the
    /// marker with a crossfade — the close a text post opened from the same
    /// marker already takes.
    var markerClose: ((UIViewController) -> RevealGeometry?)?
    /// The window close's driver — built once (its pan attaches to the view),
    /// installed as the stack's delegate whenever this page is top.
    private var markerCloseDriver: InteractiveSlideDismissal?

    /// Where a flight left THIS page from — nil whenever the open post did
    /// not come from here (the map's Case B, where the viewer arrived from a
    /// marker and has never seen this page).
    ///
    /// It is the whole of what distinguishes the card-shaped closes: one has
    /// somewhere the viewer actually was, the other does not.
    private var departure: Departure?

    private enum Departure {
        /// A post of the Recent list — a card or a mosaic tile.
        case list(PostID)
        /// A card of the Popular row, closed through the window its origin
        /// described (`ForYouRowOrigins.card`).
        case card(TextRevealOrigin)
    }


    /// The page's own hero return to the map — created once, then installed
    /// as the stack's delegate whenever this page is top, so BOTH the back
    /// button and the horizontal grab fly home to the marker instead of
    /// sliding. Retained here (the controller holds its destination weakly).
    private var mapReturnTransition: ZoomTransitionController?

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // A page opened alone (a link, #985) starts at its header.
        if opensAlone, !hasAppeared { activityPage.restAtTop() }
        hasAppeared = true
        // The BACKSTOP, on UIKit's own animation like every other install
        // (native chrome is UIKit's — see `TabBarRevealPolicy`). A tab switch
        // and a committed close install from `viewWillAppear` and find nothing
        // to do here.
        assertAppTabBar()
        // ⚠️ THE ONE INSTANT THE BAR IS BOTH PRESENT AND LAID OUT on this
        // screen: `assertAppTabBar` has just restored its state (UIKit commits
        // the frame as a model value even while it animates it in). The
        // layout pass is forced for the measurement's sake — `ForYouViewController`
        // forces one in the same place, for the same read.
        view.layoutIfNeeded()
        restingBarCover = floatingBarCover
        applyLandingOcclusion()
        // ⚠️ THE BELT FOR A CONCEALED ROW, and it has to live here.
        //
        // A window opened from a row hides that row for as long as it is in
        // the air, and only the reveal's own completion pays it back. Every
        // other way off the pushed post — an unwind, a `popToRoot`, a
        // `setViewControllers` — leaves the row invisible for the rest of the
        // session, and the driver's own `onFeedPopped` cannot cover it because
        // this page takes the delegate slot back before `didShow` reaches it.
        // Whatever happened above, nothing on THIS page may be hidden while it
        // is the screen: the same blanket rule the map applies to its markers.
        clearLandingConcealment()
        // The tap's playback claim (`ForYouGridPage.open` focuses the tapped
        // post) ends with the round trip, as the other grid hosts end it in
        // their own `viewDidAppear`. This page never did, so the last post
        // opened from it stayed pinned first in the ranking for good.
        activityPage.endPlaybackHandoff()
        shelf.endPlaybackHandoff()
        shelf.clearConcealments()
        // The flight that left here is over, whichever way it ended. A stale
        // departure would answer for the NEXT close — including the map's Case
        // B, whose whole point is that it has no departure on this page.
        departure = nil
        installMapReturnIfTop()
        syncAutoplay()
        #if DEBUG
        scheduleDebugPopIfRequested()
        scheduleDebugDrivesIfRequested()
        #endif
    }

    /// This screen shows the app's dock, so it says so itself.
    ///
    /// ⚠️ NOT REDUNDANT with the restores the feed above it runs, and the
    /// reason is a collision between two things this page does. The feed's
    /// dismissal driver puts the bar back from its `didShow` — and UIKit
    /// delivers `didShow` AFTER the appearing screen's `viewDidAppear`, which
    /// is exactly where `installMapReturnIfTop` below takes the navigation
    /// delegate for this page's own return flight. So the driver that was
    /// going to restore the dock is no longer the delegate when the news
    /// arrives, and never hears that the feed left (measured with
    /// `-grab-log`: one `didShow SnapFeedViewController` for the push, and
    /// none at all for the landing).
    ///
    /// Rather than forbid the hand-over, or make the flight forward someone
    /// else's bookkeeping, the screen that OWNS the bottom of the display
    /// asserts it — the rule the map root and the profile already follow. In
    /// `viewDidAppear`, never `viewWillAppear`: UIKit runs the latter at
    /// interactive-pop BEGIN, so a restore there would raise the dock over a
    /// feed still on screen and strand it there when the grab is released
    /// short of the threshold.
    ///
    /// Through UIKit, on its animation, never an alpha (see
    /// `TabBarRevealPolicy`) — and normally a no-op: the feed's own close
    /// has shown the bar by the time this page appears.
    private func assertAppTabBar() {
        tabBarController?.showTabBarNatively()
    }

    /// Installs the hero return each time this page becomes the top screen.
    /// The transition is built ONCE (its grab attaches a pan; a rebuild per
    /// appearance would stack recognizers) from the first source `mapReturn`
    /// yields; the DELEGATE install repeats, because every feed pushed above
    /// takes the slot and hands back whatever it captured.
    /// This page as one picture, for the flight home to dissolve into the
    /// marker's face.
    ///
    /// ⚠️ A SNAPSHOT, which this codebase is otherwise wary of — a text hero
    /// once tried photographing a page to impersonate it and the attempt is
    /// recorded as a warning. This is the other use: not a stand-in pretending
    /// to be a live screen, but one operand of a fade whose other half is a
    /// 44pt icon. Nothing is impersonated and nothing outlives the transition.
    ///
    /// `afterScreenUpdates: false` on purpose: it must not force a layout pass
    /// on the first frame of a gesture the finger is already driving, and what
    /// is already on screen is exactly what the viewer is leaving.
    private func departureStill() -> UIImage? {
        guard view.bounds.width > 0, view.bounds.height > 0 else { return nil }
        let renderer = UIGraphicsImageRenderer(bounds: view.bounds)
        return renderer.image { _ in
            view.drawHierarchy(in: view.bounds, afterScreenUpdates: false)
        }
    }

    private func installMapReturnIfTop() {
        guard let nav = navigationController, nav.topViewController === self else { return }
        // Reduce Motion: the page closes with the stack's own pop, neither a
        // flight to the marker nor a window into it (`HeroMotionPolicy`).
        guard !HeroMotionPolicy.prefersNativePush else { return }
        if let markerClose {
            installMarkerClose(markerClose, on: nav)
            return
        }
        if mapReturnTransition == nil,
           let source = mapReturn?({ [weak self] in self?.departureStill() }) {
            // `presents: false`: this controller only ever flies the page HOME.
            // Announcing a staging would tell the page a flight is arriving
            // that never does (see `ZoomTransitionController.init`).
            let transition = ZoomTransitionController(source: source, destination: self, presents: false)
            transition.attachInteractiveDismissal(to: view, axes: [.horizontal]) { [weak nav] in
                nav?.popViewController(animated: true)
            }
            transition.onSourceReturned = { [weak transition, weak nav] in
                // Landed on the map: the flow is over, and its lease ends,
                // uncovering whoever owned the stack before this page.
                guard let transition, let nav else { return }
                NavigationDelegateHub.existing(on: nav)?.release(transition)
            }
            mapReturnTransition = transition
        }
        guard let transition = mapReturnTransition else { return }
        // Leased on top on every appearance. A flight landing here (a post
        // opened from this page) stays leased beneath and still hears that it
        // landed — the hub tells every lease, which is what the old
        // `displacedDelegate` hand-off did for this one case by hand.
        NavigationDelegateHub.of(nav).lease(transition)
    }

    /// Arms the window close: the rightward grab and the back button both
    /// close this page as a window onto the map's marker.
    private func installMarkerClose(
        _ markerClose: @escaping (UIViewController) -> RevealGeometry?,
        on nav: UINavigationController
    ) {
        if markerCloseDriver == nil {
            let slide = InteractiveSlideDismissal()
            slide.resetForNewPresentation()
            slide.attach(to: self, axes: [.horizontal])
            // The same territory the hero grab had — the first tab, the
            // leading strip anywhere, and never a carousel's own drag — with
            // nothing to set: every driver asks this screen's
            // `zoomHorizontalDismissalPermitted` (`permitsDismissalGrab`).
            // No marker to close onto (it left the map): the plain slide.
            slide.fallbackSlideAxis = .horizontal
            slide.prepareForDismissal = { [weak self, weak slide] _ in
                guard let self, let slide else { return }
                slide.revealGeometry = markerClose(self)
            }
            markerCloseDriver = slide
            #if DEBUG
            // `-place-grab-demo <peak>`: the window grab onto the marker, from
            // a script — released short of the threshold for a peak under it
            // (#1638). The simulator injects no drag.
            let arguments = ProcessInfo.processInfo.arguments
            if let position = arguments.firstIndex(of: "-place-grab-demo"), position + 1 < arguments.count,
               let peak = Double(arguments[position + 1]) {
                Task { @MainActor [weak slide] in
                    try? await Task.sleep(nanoseconds: 3_000_000_000)
                    let driven = await slide?.debugPerformSwipe(peakProgress: CGFloat(peak), axis: .horizontal)
                    print("[place-grab] peak=\(peak) driven=\(driven ?? false)")
                }
            }
            #endif
        }
        markerCloseDriver?.install(on: nav)
    }

    #if DEBUG
    /// Internal (not private) only for the +QA hooks.
    var didScheduleDebugPop = false
    private var didScheduleDebugDrives = false

    /// `-maps-place-pop-demo`: pops this page ~1.5s after it becomes top —
    /// the sim can't tap the back button, and the non-interactive pop is
    /// exactly the leg that proves the hero return animator is installed.
    /// `-maps-place-scroll <pt>` drives the page's offset — the gesture this
    /// screen is read by, which the simulator cannot inject.
    private func scheduleDebugDrivesIfRequested() {
        guard !didScheduleDebugDrives else { return }
        didScheduleDebugDrives = true
        let arguments = ProcessInfo.processInfo.arguments
        func value(_ flag: String) -> Double? {
            guard let position = arguments.firstIndex(of: flag),
                  position + 1 < arguments.count else { return nil }
            return Double(arguments[position + 1])
        }
        // `-place-ink-audit`: the WCAG contrast of the name and the counters
        // against the pixels rendered behind them, once the banner's picture
        // is in (it lands after the posts, and dissolves over 0.25s).
        if arguments.contains("-place-ink-audit") {
            QAWait.until("place-ink-audit", { [weak self] in
                guard let self else { return false }
                return !showsBanner || heroHeader.debugBannerHasPicture
            }) { [weak self] in
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                    guard let self else { return }
                    view.layoutIfNeeded()
                    guard let identity = heroHeader.debugIdentityContrast() else { return }
                    let style = traitCollection.userInterfaceStyle == .dark ? "dark" : "light"
                    let body = (heroHeader.debugBodyContrast() ?? []).map { "\($0.0)=[\($0.1)]" }.joined(separator: " ")
                    let format = heroHeader.bannerFormat
                    print("PLACE-INK-AUDIT format=\(format) style=\(style) name=[\(identity.name)] region=[\(identity.handle)] \(body)")
                }
            }
        }
        // ⚠️ WAITS FOR THE PAGE'S POSTS, not for 2s. The line below used to
        // print "scrolled to X" whatever happened: on a cold run the page was
        // still empty, the offset clamped to the minimum travel (or went
        // nowhere) and the run still said it had scrolled. It now waits for
        // the active page to hold posts, and reports where it actually ended.
        if let offset = value("-maps-place-scroll") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                QAWait.until("-maps-place-scroll \(offset)", { [weak self] in
                    guard let self else { return false }
                    let grid = self.activityPage
                    return !grid.posts.isEmpty
                }) { [weak self] in
                    guard let self else { return }
                    debugScrollActivePage(to: CGFloat(offset))
                    let actual = hostedPages[activeIndex].verticalOffset
                    print("[place] scrolled to \(offset) (actual \(Int(actual)), tab \(activeIndex))")
                }
            }
        }
        // `-place-scroll-sweep`: once the page holds posts and its picture,
        // scrolls it from the top to 240pt and back, frame by frame, 3s each
        // way — the profile's `-profile-scroll-sweep` — and says what each
        // frame cost (`HERO-SCROLL place …` on standard error, see
        // `HeroScrollFrameProbe`).
        if arguments.contains("-place-scroll-sweep") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                QAWait.until("-place-scroll-sweep", { [weak self] in
                    guard let self else { return false }
                    let grid = self.activityPage
                    return !grid.posts.isEmpty && (!self.showsBanner || self.heroHeader.debugBannerHasPicture)
                }) { [weak self] in
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                        guard let self else { return }
                        debugSweepStep(
                            began: CACurrentMediaTime(), probe: HeroScrollFrameProbe(name: "place", root: headerHost)
                        )
                    }
                }
            }
        }
        // `-place-stretch-sweep`: the profile's `-profile-stretch-sweep` —
        // the page pulled past its top, the banner stretching, held, let go
        // and settled (`HERO-SCROLL place-stretch/<phase> …`). No refresh:
        // a refresh is asked by a drag ENDING past the threshold, which a
        // scripted offset never does — `-place-pull-refresh` does.
        if arguments.contains("-place-stretch-sweep") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                QAWait.until("-place-stretch-sweep", { [weak self] in
                    guard let self else { return false }
                    let grid = self.activityPage
                    return !grid.posts.isEmpty && (!self.showsBanner || self.heroHeader.debugBannerHasPicture)
                }) { [weak self] in
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                        guard let self else { return }
                        debugStretchStep(
                            began: CACurrentMediaTime(),
                            probe: HeroScrollFrameProbe(name: "place-stretch", root: headerHost), phase: nil
                        )
                    }
                }
            }
        }
        // `-place-pull-refresh`: releases a pull past the threshold on the
        // active page through the drag's own end, the path a finger takes,
        // and says how long the spinner ran — or `[qa] GAVE UP`, which is
        // what a release through the stock control did while nothing
        // answered it.
        if arguments.contains("-place-pull-refresh") {
            QAWait.until("-place-pull-refresh ready", { [weak self] in
                guard let self else { return false }
                return !renderedActivity.isEmpty && !isLoading
            }) { [weak self] in
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                    guard let self else { return }
                    let began = CACurrentMediaTime()
                    let rendersBefore = renders
                    debugReleasePull()
                    print("[place] pull released refreshing=\(debugIsRefreshing)")
                    QAWait.until("-place-pull-refresh spinner", timeout: 10, { [weak self] in
                        self?.debugIsRefreshing == false
                    }) { [weak self] in
                        guard let self else { return }
                        print("[place] pull settled after"
                            + " \(Int((CACurrentMediaTime() - began) * 1000))ms"
                            + " renders=\(renders - rendersBefore)")
                    }
                }
            }
        }
        // `-maps-place-open-tile <index>`: opens a post from whichever tab is
        // up, which is the gesture that decides where a dismissal has to come
        // BACK to. Runs after the tab drive so a run can ask for "open the
        // third post of the Activity list" — the case where the departure
        // screen and the landing screen can disagree, and the only way to see
        // that disagreement is to leave from the tab that is not the default.
        //
        // ⚠️ WAITS FOR THE TILE TO EXIST, not for 2.6s: a cold page had no
        // posts yet and the open below was a silent no-op (only `posts=-1` or
        // `post=nil` in the line hinted at it). It also remembers which flight
        // was the latest BEFORE it opened, so `-maps-place-tile-dismiss` can
        // tell this tile's flight from the one before it.
        if let index = value("-maps-place-open-tile").map(Int.init) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.6) { [weak self] in
                QAWait.until("-maps-place-open-tile \(index)", { [weak self] in
                    guard let self else { return false }
                    let grid = self.activityPage
                    return grid.posts.indices.contains(index)
                }) { [weak self] in
                    guard let self else { return }
                    debugFlightBeforeTileOpen = ZoomTransitionController.debugMostRecent
                    debugDidOpenTile = true
                    let grid: ForYouGridPage? = activityPage
                    // The ELECTION, not just the tap: a text row that opens with
                    // no window is a plain push, and a plain push looks like a
                    // perfectly good animation. Only the line says which happened.
                    let post = grid?.posts.indices.contains(index) == true
                        ? grid?.posts[index] : nil
                    let window = post.flatMap { p in grid.flatMap { textRowReveal(for: p, in: $0) } }
                    print("[place] opening tile \(index) from tab \(activeIndex)"
                        + " posts=\(grid?.posts.count ?? -1)"
                        + " post=\(post?.id.rawValue ?? "nil")"
                        + " hero=\(post.flatMap { grid?.heroAppearance(for: $0.id) } != nil)"
                        + " window=\(window != nil)")
                    // ⚠️ THROUGH THE DELEGATE, NOT THE HOST'S OWN METHOD. Calling
                    // `openTile` directly skips `didSelectItemAt` and therefore
                    // `ForYouGridPage.open(at:)`, which is where a tap REMEMBERS
                    // the row to settle clear of the chrome. So the one thing this
                    // hook exists to exercise — where a dismissal comes back to —
                    // was the one thing it could not reach, and a run showed a card
                    // returning still half behind the tab bar whether the code was
                    // right or wrong. `ForYouGridPage.debugSelectItem` carries the
                    // same warning about `-foryou-open`, which made this mistake
                    // first.
                    if grid?.debugSelectItem(at: index) != true {
                        openTile(at: index, in: grid)
                    }
                }
            }
        }
        // `-maps-place-tile-dismiss <seconds>`: grabs the feed that tile just
        // opened, back to this page. The flight is `presentSnapFeedHero`'s, not
        // this screen's, so the harness reaches it the only way anything can —
        // `debugMostRecent`, which is exactly the "present one screen and
        // dismiss that one" usage it exists for. Delay is absolute rather than
        // chained off the open so a run can settle a page first.
        if let after = value("-maps-place-tile-dismiss") {
            // ⚠️ ITS OWN AXIS, not the process-wide `-zoom-demo-grab-vertical`.
            // A run that reaches this page by a VERTICAL grab and then leaves
            // the post above it HORIZONTALLY needs both in one process, and a
            // single global flag cannot say that — which is how the escape leg
            // went unscripted while the flag was set for the leg before it.
            // Horizontal by default: that is the escape this hook exists for.
            let axis: ZoomDismissAxis =
                arguments.contains("-maps-place-tile-dismiss-vertical") ? .vertical : .horizontal
            // ⚠️ THE TILE'S OWN FLIGHT, LANDED — not whatever is most recent
            // at `after` seconds. If the open failed or came late,
            // `debugMostRecent` was still the PREVIOUS flight (the one that
            // brought this page up), and the grab dismissed the wrong screen
            // while the line said it had scripted the tile's. The delay stays
            // as the floor; past it the grab waits for a controller NEWER than
            // the one the open hook saw, with a screen above this page and no
            // transition running.
            let requiresTileOpen = arguments.contains("-maps-place-open-tile")
            DispatchQueue.main.asyncAfter(deadline: .now() + after) { [weak self] in
                QAWait.until("-maps-place-tile-dismiss", { [weak self] in
                    guard let self, let nav = self.navigationController,
                          nav.topViewController !== self, nav.transitionCoordinator == nil,
                          let recent = ZoomTransitionController.debugMostRecent
                    else { return false }
                    guard requiresTileOpen else { return true }
                    return self.debugDidOpenTile && recent !== self.debugFlightBeforeTileOpen
                }) {
                    if !requiresTileOpen {
                        print("[qa] -maps-place-tile-dismiss: no -maps-place-open-tile in this run;"
                            + " grabbing the most recent flight, unverified")
                    }
                    print("[place] scripting tile-feed dismissal axis=\(axis)")
                    ZoomTransitionController.debugMostRecent?.debugScriptedGrab(axis: axis)
                }
            }
        }
    }

    /// The latest flight controller at the moment `-maps-place-open-tile`
    /// fired — WEAK, so remembering it keeps nothing alive; a controller that
    /// has since gone reads as nil, which is still "not the tile's".
    private weak var debugFlightBeforeTileOpen: ZoomTransitionController?
    private var debugDidOpenTile = false
    #endif
    /// How many posts seed a feed opened from a tile — the same window (and
    /// the same reason) as For You's.
    private static let seedWindow = 40

    init(
        postIDs: [PostID],
        placeName: String = "",
        rank: PlaceRankBadge? = nil,
        identity: PlaceIdentity? = nil,
        imagePipeline: ImagePipeline,
        videoPlayback: VideoPlaybackController?,
        following: ClusterGalleryFollowing? = nil,
        wallet: WalletStore? = nil,
        makeWalletSheet: (@MainActor () -> UIViewController)? = nil,
        showsBalance: Bool = true,
        entities: EntityStore? = nil,
        loadPosts: @escaping () async throws -> [GalleryPost],
        loadMore: ((String?) async throws -> PlacePostsPage)? = nil,
        presence: SectionPresenceStore = .shared,
        openPost: @escaping (UIViewController, SnapFeedHeroOrigin, [PostID]) -> Void
    ) {
        self.presence = presence
        self.loadMore = loadMore
        self.postIDs = postIDs
        self.placeName = placeName
        self.rank = rank
        self.shareURL = identity?.shareURL
        self.dockPin = identity?.dockPin
        // The flag fills the disc a profile's avatar stands in — or, for a
        // place with none, the disc's own neutral fill.
        let flag = UIImageView(image: identity?.flag)
        flag.contentMode = .scaleAspectFill
        flag.accessibilityIdentifier = "place.identity.flag"
        self.flagView = flag
        // Ranking and Likes (the owner, 2026-10-23): no rank, no Ranking
        // column; a dash for the likes until the posts arrive (`renderCorpus`).
        // The banner's skeleton until the posts say which picture, if any
        // (the owner, 2026-10-26, #1752).
        headerContent = HeroHeaderContent(
            title: Self.heroTitleComponents(of: placeName).name, subtitle: identity?.subtitle ?? "",
            counterValues: [rank?.positionText, "—"], bannerPending: true
        )
        self.imagePipeline = imagePipeline
        self.following = following
        self.wallet = wallet
        self.makeWalletSheet = makeWalletSheet
        self.showsBalance = showsBalance
        self.loadPosts = loadPosts
        self.openPost = openPost
        self.anchorID = postIDs.first ?? PostID("")
        let page = ForYouGridPage(imagePipeline: imagePipeline, style: .discover, videoPlayback: videoPlayback)
        self.activityPage = page
        let shelf = PostShelfSection(imagePipeline: imagePipeline, videoPlayback: videoPlayback)
        self.shelf = shelf
        self.lead = GridLeadStack(sections: [shelf])
        // The profile's header with the place's identity (#1656): the flag in
        // the disc, Ranking and Likes; the action row is `configureActionRow`'s.
        let header = HeroHeaderView(imagePipeline: imagePipeline, counters: ["Ranking", "Likes"], avatar: .custom(flag))
        header.bannerVideoPool = videoPlayback
        // A place's band card rests COLLAPSED (the owner, 2026-10-23): the
        // height a profile's shrinks to, its flag just under the bar.
        header.bandRestsCollapsed = true
        // One page, so no selector is ever placed: the strip is the
        // container's, titled for the day a place has tabs.
        // ⚠️ NO DOCKED SLOT: with no selector the WHOLE header climbs under
        // the bar, the tray included — stopping a strip's height short left
        // the Pin and the QR code floating over the posts.
        super.init(
            header: header, pager: HeroPagePager(tabs: [PlaceProfileTab.posts], pages: [page]),
            selectorBar: PagedTabBar(titles: ["Posts"], style: .navigationTitle),
            dockedSlot: 0
        )
        header.configure(with: headerContent)
        shelf.title = "Popular"
        // Its title over skeleton cards until the place's posts land (#1296)
        // — ⚠️ only for a place whose Popular had posts last time (#1773):
        // never seen, or empty then, it fades in rather than shimmer.
        shelf.isLoading = (presenceScreen.flatMap { presence.count(screen: $0, section: "popular") } ?? 0) > 0
        lead.listTitle = "Recent"
        // The list and the row draw the same cards For You does, and their
        // like chips stake the same way.
        let staking = wallet.map { PostCardStaking(wallet: $0, entities: entities) }
        activityPage.staking = staking
        shelf.staking = staking
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    deinit {
        loadTask?.cancel()
        moreLoad?.cancel()
    }

    override func viewDidLoad() {
        // The hero page's layout: the pages, the header over them, the
        // banner behind, the pull's indicator (#1655).
        super.viewDidLoad()
        activityPage.render(.loading)
        // "Try Again" and a released pull reload the whole place
        // (`heroPageRefresh`).
        // Near the list's end: the place's next page (#643).
        if loadMore != nil {
            activityPage.onNearEnd = { [weak self] in self?.loadMorePosts() }
        }
        activityPage.onItemTapped = { [weak self] index in
            self?.openTile(at: index, in: self?.activityPage)
        }
        wireRails()
        // The comment chip opens the post, not the thread — deliberately, for
        // now. Landing ON the comments needs the pushed feed itself
        // (`openComments(for:revealingFrom:)`), and this screen never holds
        // it: `openPost` hands an origin across the feature seam and the
        // builder constructs the destination. Widening that seam for a
        // secondary affordance is the wrong trade; a chip that opens the post
        // is honest, where a chip that did nothing would not be.
        // ⚠️ THE COUNT OPENS THE THREAD, not just the post.
        //
        // It used to open the post and stop there, and the note that stood here
        // argued the seam was not worth widening for "a secondary affordance".
        // It is the only way to ask for a media post's thread directly — the
        // page opens onto its photograph and the thread is a second surface —
        // and For You's identical chip has done this all along. One control,
        // two screens, one behaviour.
        activityPage.onItemCommentsTapped = { [weak self] index in
            self?.openTile(at: index, in: self?.activityPage, showingComments: true)
        }
        // No author rows here: the reporting and social-graph seams are not
        // threaded into this screen, and a row that cannot act is worse than
        // none. The "..." still offers the post's own rows and View Profile
        // (#1498 §3), which the page services itself.
        activityPage.authorMenuActions = { _ in [] }
        configureNavigationItems()
    }

    // MARK: - Popular and Recent

    /// For You's coupling of its rows and its list
    /// (`ForYouViewController.viewDidLoad`, the hashtag page's `wireDiscover`):
    /// the titles' pushes, the cards' flights, and ONE player budget the two
    /// share — the list leaves the players the row has claimed.
    private func wireRails() {
        shelf.visibleBand = { [weak self] in self?.visibleBand() }
        lead.onHeightChange = { [weak self] in self?.updateLeadHeight() }
        // A card's flight is the SHELF's (#1271).
        shelf.heroContext = .init(page: activityPage, host: view, seedWindow: Self.seedWindow)
        shelf.shouldOpen = { [weak self] in
            guard let self else { return false }
            return navigationController.map { FeedFeatureBuilder.canOpen(from: self, on: $0) } ?? true
        }
        shelf.onOpen = { [weak self] open in
            guard let self else { return }
            departure = open.origin.textReveal.map(Departure.card)
            openPost(self, open.origin, open.stream.map(\.id))
        }
        shelf.onViewAll = { [weak self] in self?.pushPopularList() }
        lead.onListTitleTapped = { [weak self] in self?.pushGallery() }
        lead.listTitleAccessibilityHint = "Shows every post"
        activityPage.onViewAllTapped = { [weak self] in self?.pushGallery() }
        activityPage.onAutoplayReconcile = { [weak self] allowingStarts in
            self?.shelf.updateAutoplay(allowingStarts: allowingStarts, notifiesClaimChange: false)
        }
        activityPage.playerReserve = { [weak self] in self?.shelf.claimedPlayers ?? 0 }
        shelf.onPlayerClaimChange = { [weak self] in self?.activityPage.updateAutoplay() }
    }

    /// Sizes the list's leading header to the rows it holds.
    ///
    /// ⚠️ THE PAGER'S WIDTH, not the page's: the page hangs in the pager's
    /// scroll view, one viewport wide, and is placed only in the pager's own
    /// layout pass — after this screen's. Read off the page, the width was
    /// still zero when a landing staged the page off screen, the Popular row
    /// was never sized, and every close fell back to Recent's head with the
    /// header docked.
    private func updateLeadHeight() {
        let width = heroPager.bounds.width
        guard width > 0 else { return }
        activityPage.setLead(lead, height: lead.preferredHeight(forWidth: width))
    }

    /// The part of the screen the viewer can see, in the rows' space — what a
    /// row's card must be half inside to play.
    private func visibleBand() -> CGRect? {
        guard shelf.window != nil, view.window != nil else { return nil }
        let band = view.bounds.inset(by: UIEdgeInsets(
            top: view.safeAreaInsets.top, left: 0, bottom: barCover, right: 0
        ))
        return shelf.convert(band, from: view)
    }

    /// The Popular row's posts, in its order.
    private var popularPosts: [GalleryPost] { shelf.cards }

    /// "Popular": the place's posts by popularity, as For You's pushed
    /// Following list draws a run of posts.
    private func pushPopularList() {
        guard let makePostList, let navigationController,
              navigationController.transitionCoordinator == nil,
              FeedFeatureBuilder.canOpen(from: self, on: navigationController)
        else { return }
        let list = makePostList()
        list.render(.content(Self.popular(self.corpus, limit: nil)), newPosts: [])
        pushLeavingTheBackSwipe(list, on: navigationController)
    }

    /// "Recent" and every "View all": For You's media gallery over the
    /// place's media, in the list's order.
    private func pushGallery() {
        guard let makeGallery, let navigationController,
              navigationController.transitionCoordinator == nil,
              FeedFeatureBuilder.canOpen(from: self, on: navigationController)
        else { return }
        let gallery = makeGallery()
        gallery.render(.content(GalleryFilter.Format.media.filtering(activityPage.posts)))
        pushLeavingTheBackSwipe(gallery, on: navigationController)
    }

    /// ⚠️ A PLAIN PUSH LEAVES THE DELEGATE SLOT EMPTY — the pushed screens'
    /// full-surface back swipe (the owner, 2026-10-16: "only from the left
    /// edge"; For You's own contract, #670 / `ForYouPushedBackSwipeTests`).
    /// UIKit refuses the iOS 26+ full-surface back swipe on a screen whose pop
    /// brings the tab bar back while ANY navigation delegate is in the slot,
    /// and this page holds it with its way home to the map (the marker's
    /// window, or the hero return) whenever it is top. Released for the push;
    /// `viewDidAppear` takes it back (`installMapReturnIfTop`).
    private func pushLeavingTheBackSwipe(_ screen: UIViewController, on nav: UINavigationController) {
        let hub = NavigationDelegateHub.existing(on: nav)
        if let markerCloseDriver { hub?.release(markerCloseDriver) }
        if let mapReturnTransition { hub?.release(mapReturnTransition) }
        nav.pushViewController(screen, animated: true)
    }

    /// A Popular card opens the way For You's Following cards do
    /// (`ForYouViewController.openCard`, `ForYouRowOrigins.card`), and its
    /// close comes home through the window the origin describes.
    private func openCard(at index: Int) { shelf.openCard(at: index) }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        // No accessory any more (one page, no strip): the tab bar is the
        // app's, asserted from `viewDidAppear` (`assertAppTabBar`).

        syncAutoplay()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        // Off screen, this page holds no claim on the shared player pool —
        // the feed pushed above it is about to want every loan.
        for hosted in hostedPages { hosted.setAutoplayActive(false) }
        shelf.setAutoplayActive(false)
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        // ⚠️ THE REVEAL THIS PAGE ARMED AND NEVER APPLIED.
        //
        // `ForYouGridPage.open(at:)` remembers the tapped post on EVERY tap, on
        // every host, so that the row can be settled clear of the chrome once
        // the post is covering the grid — where the move costs nothing to look
        // at. For You and the profile both spend it from their own
        // `viewDidDisappear`. This page never did, so a card tapped while it
        // was half behind the tab bar departed from that rect and, because a
        // flight's landing deliberately does not scroll (see
        // `ForYouGridZoomSource`), came home to it. Filmed: a card cut off at
        // the foot, opened, closed, and cut off in exactly the same way.
        //
        // ⚠️ THE COVER IS ALREADY ON THE PAGE, and it has to be. This used to
        // hand over `floatingBarCover` here — but the bar was taken down before
        // the push, so what it measured was the safe area's 34 against a bar
        // covering 83, and the top was left to the content inset, which on this
        // page is the header's whole reserved range rather than anything
        // covering the list. The page is told both, from `viewDidAppear`, while
        // the bar is still up.
        //
        // The MOMENT stays. It is where For You and the profile spend the same
        // reveal: hidden behind the covering post, settled before the
        // dismissal reads the cell's rect, and — unlike a pre-grab hook — it
        // still runs when the viewer leaves by the chevron or a system pop
        // rather than by a drag that may never come.
        for hosted in hostedPages {
            let page = hosted
            page.applyPendingReveal()
        }
    }

    /// The bar's cover as measured while it was still on screen.
    ///
    /// ⚠️ THE ONE MOMENT THIS NUMBER IS NEEDED IS THE ONE MOMENT IT CANNOT BE
    /// READ. `presentSnapFeedHero` takes the tab bar down BEFORE it pushes, and
    /// it is only restored when the source returns — so every reveal on this
    /// screen, the departure reveal and all four landing reveals alike, runs
    /// while the bar is gone and `floatingBarCover` degrades to the safe area's
    /// 34 against a bar that really covers 83. A card "revealed" against 34 is
    /// a card left 37pt behind the bar, which is one of the three filmed
    /// reports. For You caches the same number in its own `viewDidAppear`, for
    /// the same reason, in the same words.
    private var restingBarCover: CGFloat = 0

    /// `max` rather than the cache alone, so a landing staged on a page that
    /// has never appeared still gets the best number available.
    private var barCover: CGFloat { max(restingBarCover, floatingBarCover) }

    /// The foot chrome moved at rest — the tab bar collapsed, or the strip
    /// re-sized — so the cached cover is stale.
    ///
    /// ⚠️ AT REST ONLY. Mid-flight the chrome is being animated by a driver
    /// that will put it back, and re-publishing then hands the pages a number
    /// from the middle of an animation.
    private func chromeDidMove() {
        guard view.window != nil,
              navigationController?.topViewController === self,
              transitionCoordinator == nil
        else { return }
        let cover = floatingBarCover
        guard abs(cover - restingBarCover) > 0.5 else { return }
        restingBarCover = cover
        applyLandingOcclusion()
    }

    /// Exactly one page may drive playback: two grids competing for one pool
    /// is how a working set of six turns into a queue nobody wins. For You's
    /// pager makes the same call from the same three places (settle, tab tap,
    /// appearance).
    private func syncAutoplay() {
        for (index, hosted) in hostedPages.enumerated() {
            hosted.setAutoplayActive(index == activeIndex)
        }
        shelf.setAutoplayActive(true)
    }

    // MARK: - The header (the hero page's, #1656)

    /// Re-applies the header's content: the name and region, the Ranking and
    /// the Likes, the banner's picture.
    private func applyHeaderContent() {
        heroHeader.configure(with: headerContent)
    }

    /// The row under the identity — the profile's tray for a place (#1598):
    /// the pin capsule takes the width the bubbles leave, the bubbles are
    /// circles (`HeroHeaderView.setActions`). With no pin, the bubbles stand
    /// at the leading edge and a spacer takes the rest.
    private func configureActionRow() {
        var actions: [HeroHeaderAction] = []
        if dockPin != nil {
            dockPinButton.accessibilityIdentifier = "place.dockPin"
            dockPinButton.addAction(UIAction { [weak self] _ in self?.dockPinTapped() }, for: .primaryActionTriggered)
            actions.append(.capsule(dockPinButton))
            renderDockState(dockPin?.isFollowing() ?? false, animated: false)
        }
        if following != nil {
            starButton.accessibilityIdentifier = "place.star"
            starButton.addAction(UIAction { [weak self] _ in self?.starTapped() }, for: .primaryActionTriggered)
            actions.append(.bubble(starButton))
            renderFollowState(following?.isFollowing() ?? false, animated: false)
        }
        if shareURL != nil {
            qrButton.accessibilityIdentifier = "place.qrCode"
            qrButton.accessibilityLabel = "QR code"
            qrButton.addAction(UIAction { [weak self] _ in self?.presentQRCode() }, for: .primaryActionTriggered)
            actions.append(.bubble(qrButton))
        }
        if dockPin == nil, !actions.isEmpty { actions.append(.capsule(UIView())) }
        heroHeader.setActions(actions)
        // Nothing to offer: no row, as on the profile card's sheet.
        heroHeader.showsActionTray = !actions.isEmpty
    }

    /// The pin's two states: an offer, then the fact.
    static func dockPinContent(docked: Bool) -> AppButton.Content {
        docked
            ? AppButton.Content(title: "Pinned to Map", symbol: "mappin.circle.fill")
            : AppButton.Content(title: "Add Pin to Map", symbol: "mappin")
    }

    private func dockPinTapped() {
        MemberGates.perform(.followPlace, from: self) { [weak self] in
            guard let self, let dockPin = self.dockPin else { return }
            let docked = dockPin.toggle()
            // A control in the content changes at once, its toast beside it
            // (`Feedback`, #1447) — one id, so a quick re-tap replaces it.
            self.renderDockState(docked, animated: true)
            self.confirmDock(self, docked)
        }
    }

    /// Shows the pin's toast; a seam so tests can see it fired.
    var confirmDock: (UIViewController, Bool) -> Void = { screen, docked in
        Feedback.success(
            PlaceProfileViewController.dockToast(docked: docked),
            symbol: docked ? "mappin.circle.fill" : "mappin.slash",
            from: screen, id: "place.dockPin"
        )
    }

    /// The toast confirming a pin or an unpin.
    static func dockToast(docked: Bool) -> String {
        docked ? "Pinned to the map's dock" : "Removed from the map's dock"
    }

    private func renderDockState(_ docked: Bool, animated: Bool) {
        isDocked = docked
        dockPinButton.setContent(Self.dockPinContent(docked: docked), animated: animated)
        dockPinButton.accessibilityLabel = docked ? "Unpin from Map" : "Add Pin to Map"
    }

    /// The place's share sheet — the PROFILE'S OWN (`ShareSheet`, shared):
    /// its QR card with the place's flag punched in, its name and country,
    /// and the actions tray. No row of people to send it to: the page has no
    /// source of them, and a row with nobody in it is not drawn.
    private func presentQRCode() {
        guard let sheet = makeShareSheet() else { return }
        // The system sheet opens once this one is gone — the profile's
        // hand-off (presenting from a sheet would stack two).
        sheet.onSystemShare = { [weak self] card, image in
            guard let self else { return }
            let activity = UIActivityViewController(
                activityItems: [ShareItemSource(card: card, icon: image), image], applicationActivities: nil
            )
            activity.popoverPresentationController?.sourceItem = self.qrButton
            self.present(activity, animated: true)
        }
        present(sheet, animated: true)
    }

    private func makeShareSheet() -> ShareSheetViewController? {
        guard let shareURL else { return nil }
        let card = ShareCard(
            displayName: headerContent.title,
            handle: headerContent.subtitle,
            avatarURL: nil,
            avatarImage: flagView.image,
            url: shareURL
        )
        return ShareSheetViewController(
            card: card,
            imagePipeline: imagePipeline,
            targeting: nil,
            deviceCornerRadius: ScreenGeometry.cornerRadius(behind: view),
            fallbackWidth: view.bounds.width
        )
    }
    /// What actually COVERS the hosted list right now, top and bottom.
    ///
    /// Not the content inset: this page reserves the header's whole height as
    /// scrollable range, and most of that is room the content scrolls INTO
    /// rather than chrome it hides behind. What genuinely hides a row is the
    /// header band wherever it currently sits — its own height at rest, the
    /// docked selector once it has climbed — and the tab bar at the foot.
    ///
    /// ⚠️ THE TAB BAR IS MEASURED, NOT ASSUMED. It floats: it draws over the
    /// content without insetting it, so `safeAreaInsets.bottom` understates it
    /// by the height of the bar itself (34 against 83 on an iPhone 17 Pro).
    /// Taking the larger of the two means a landing clears whichever is really
    /// in the way.
    private var landingOcclusion: UIEdgeInsets {
        // Measured AT REST (see `restingBarCover`), because at the instant any
        // reveal on this screen asks, the bar has already been taken down.
        let bottom = barCover
        // ⚠️ THE DOCKED BAND, NOT THE HEADER WHERE IT HAPPENS TO BE STANDING.
        //
        // The header is not a permanent occluder: the list scrolls UNDER it and
        // it climbs away, so the room a landing can actually reach is the room
        // left once it has docked. Measured at rest instead — its full height,
        // some 520pt of a 874pt screen — the visible band came out at ~270pt,
        // every Activity card was "taller than the gap", and `offset(toReveal:)`
        // took its align-to-the-top branch and moved nothing. Which is exactly
        // the report: a card left cut off by the tab bar with no scroll at all.
        //
        // The docked band is the navigation bar alone now — no selector lands
        // in it any more. That is what still covers the list once the header
        // has gone.
        // The chrome, not the safe area: a landing stages this page off a
        // window, where the safe area is still zero (`chromeTop`).
        return UIEdgeInsets(top: chromeTop, left: 0, bottom: bottom, right: 0)
    }

    /// Hands both tabs what actually covers them.
    ///
    /// ⚠️ BOTH, not just Activity. The Discover grid has the identical defect —
    /// a 268pt portrait brick also overruns a 163pt band — so fixing the list
    /// alone would leave the grid parking its tapped tile off the screen.
    private func applyLandingOcclusion() {
        let cover = landingOcclusion
        for hosted in hostedPages {
            hosted.setChromeOcclusion(cover)
        }
    }

    /// The header height the pages were last inset by (#1599).
    private var laidOutHeaderHeight: CGFloat = 0

    override func viewDidLayoutSubviews() {
        // The container's pass: the header measured, the pages inset by it,
        // the travel, the detents.
        super.viewDidLayoutSubviews()
        let header = headerHeight
        // ⚠️ A LIST AT REST AT ITS TOP STAYS THERE when the header changes
        // height under it (#1599): the banner going for a text-only place, a
        // page opened alone growing its header as its first posts land. The
        // offset was the old header's; left alone the list opened scrolled
        // by the difference, the identity under the bar.
        let restedAtTop = activityPage.verticalOffset.magnitude < 1 && header != laidOutHeaderHeight
        laidOutHeaderHeight = header
        if restedAtTop { activityPage.restAtTop() }
        // Derived from the safe area, so a rotation or a size change is a
        // different answer. Idempotent — a plain assignment — and
        // deliberately NOT re-measuring `restingBarCover`, which runs during
        // the push when the bar is already down. After the container's
        // occlusion, which it refines with the bar's resting cover.
        applyLandingOcclusion()
        // The rows' height depends on the WIDTH (a card is a fraction of it).
        updateLeadHeight()
        // The foot chrome may have moved at rest (the tab bar collapsing).
        chromeDidMove()
    }

    /// A released pull, or "Try Again": the whole place again.
    override func heroPageRefresh() {
        refresh()
    }

    /// Splits the gallery title's "Name • Kind Cluster" shape into the hero
    /// title's two lines: the name big, the kind whispered above it. A title
    /// with no separator is all name — the hero simply has no kind line.
    static func heroTitleComponents(of title: String) -> (name: String, kind: String?) {
        guard let range = title.range(of: " • ") else { return (title, nil) }
        let name = String(title[..<range.lowerBound])
        let kind = String(title[range.upperBound...])
        return (name, kind.isEmpty ? nil : kind)
    }

    /// Starts the one hydration this screen ever does. Called by the builder
    /// at CREATION, not on first appearance: the profile spends its early
    /// life invisible beneath the feed (the two-VC insertion never even loads
    /// a mid-stack view), and the first thing anyone sees of it is the
    /// landing of a dismissal — which must find tiles, not a skeleton.
    /// Idempotent; re-entry is a no-op.
    func beginLoading() {
        guard loadTask == nil else { return }
        loadViewIfNeeded()
        load()
    }

    /// Pull-to-refresh, and the failed state's "Try Again" — the profile's
    /// rule (`ProfileViewModel.refresh`): the page REVALIDATES IN PLACE.
    ///
    /// ⚠️ BOTH PAGES CARRIED A `UIRefreshControl` THAT NOTHING ANSWERED. A
    /// release through it started a spinner that never stopped (measured:
    /// still spinning 10s on, `-place-pull-refresh`), a real drag never even
    /// tripped it under the floating header, and "Try Again" was a button
    /// that did nothing. A place's posts move — likes tick, a member is
    /// deleted — so the pull is kept and given the profile's behaviour, its
    /// indicator included (`HeroPullToRefreshView`), rather than removed:
    /// - what is on screen stays until the new hydration lands (no bones);
    /// - an answer identical to the one on screen publishes nothing;
    /// - the spinner stops when the load SETTLES, however it settled —
    ///   landed, identical, failed or superseded.
    ///
    /// Coalesced: a pull while a load is in flight starts nothing, and that
    /// load's settle ends its spinner — including the first hydration's.
    func refresh() {
        guard !isLoading else { return }
        // A page with nothing to keep (it failed) shows that it is trying
        // again.
        if renderedMembers == nil {
            activityPage.render(.loading)
        }
        load()
    }

    /// The one hydration path: the builder's first load and every refresh.
    private func load() {
        isLoading = true
        loadTask = Task { [weak self] in
            guard let self else { return }
            defer { settleLoad() }
            do {
                let members = try await loadPosts()
                guard !Task.isCancelled else { return }
                render(members)
            } catch {
                guard !Task.isCancelled else { return }
                // A revalidation that failed leaves the place it already
                // showed: those posts are still the place's, and replacing
                // them with an error over a pull would trade a stale page for
                // an empty one.
                guard renderedMembers == nil else { return }
                // The members were already open in the feed above, so a failed
                // hydration here is almost certainly transient — say so
                // plainly rather than rendering a dead end.
                activityPage.render(.failed(message: "Couldn't load this place's posts."))
                endBannerWait()
            }
        }
    }

    /// Where every load ends, and so where the spinner stops — a refresh that
    /// brought nothing new publishes nothing, so no render can be the thing
    /// that stops it.
    private func settleLoad() {
        isLoading = false
        pullIndicator.endRefreshing()
    }

    /// One place fans the hydrated corpus out to every surface of the page,
    /// so they can never disagree about what the place contains.
    ///
    /// ⚠️ THE SAME CORPUS AGAIN IS NO NEWS. Compared before anything is
    /// touched: re-rendering identical members would re-rank the Activity
    /// list (undoing the post a close from the map moved to its head), reset
    /// the counter and fetch and cross-dissolve the banner again — a
    /// landing's worth of work for a refresh that changed nothing.
    private func render(_ members: [GalleryPost]) {
        guard members != renderedMembers else { return }
        // ⚠️ A REFRESH IS A RE-RANKED CORPUS, NOT A PAGE APPENDED. The grid
        // reads a delivery that only ADDS posts as pagination and inserts
        // them at the tail — so a new post more popular than everything on
        // screen landed last (caught by `aRefreshThatBringsNewPostsLandsThemInPlace`).
        // For You says the same on a corpus reset (`onCorpusReset`).
        let isRefresh = renderedMembers != nil
        renderedMembers = members
        renders += 1
        // The place's later pages stay (#643): a refresh is the pins again,
        // and a pin a page had brought is the pin's now.
        let pinned = Set(members.map(\.id))
        extraPosts.removeAll { pinned.contains($0.id) }
        renderCorpus(reset: isRefresh)
        // No pins yet more pages to come (a page opened alone): the banner
        // keeps its skeleton for the first page's top post.
        if !members.isEmpty || !hasMorePosts {
            renderBanner(for: Self.bannerPost(in: Self.gallery(members)), shows: Self.showsBanner(for: members))
        }
    }

    /// Whether the page wears a banner (#1599): not when the place's most
    /// popular post is words.
    private(set) var showsBanner = true

    /// Whether a place with these posts wears a banner: not when its most
    /// popular post — `ranked`'s first — is text-only.
    static func showsBanner(for posts: [GalleryPost]) -> Bool {
        ranked(posts).first.map { $0.kind != .text } ?? true
    }

    /// The pins, then the place's later pages in the server's order (#643),
    /// fanned out to the Popular row, the Recent list and the counters.
    ///
    /// ⚠️ A LATER PAGE IS APPENDED, NOT RE-ORDERED IN: the pins take the
    /// `recent` order and the pages follow in the server's, so a page landing
    /// never moves a card or a tile already on screen.
    private func renderCorpus(reset: Bool) {
        let members = renderedMembers ?? []
        if reset { activityPage.invalidateIncrementalUpdates() }
        // The last stretch of tiles is planned whole only once the place has
        // no page left (`MosaicChunkPlanner`).
        activityPage.setCorpusComplete(!hasMorePosts)
        var recent = Self.recent(members) + extraPosts
        // The post a close from the map put first stays first: a later page
        // landing as the page appears must not take it back.
        if let landedHead {
            recent = [landedHead] + recent.filter { $0.id != landedHead.id }
        }
        // ⚠️ A PAGE OPENED ALONE HAS NO PINS (a shared link, #985): its first
        // posts are the place's first page, asked for now, behind the
        // skeleton — never the empty state before the server has answered.
        if recent.isEmpty, hasMorePosts, emptyPagesInARow < Self.maxEmptyPagesInARow {
            activityPage.render(.loading)
            loadMorePosts()
        } else {
            activityPage.render(recent.isEmpty
                ? .empty(.init(title: "Nothing has happened here yet"))
                : .content(recent))
        }
        let popular = Self.popularShelf(self.corpus)
        shelf.apply(popular)
        if let presenceScreen { presence.remember(popular.posts.count, screen: presenceScreen, section: "popular") }
        updateLeadHeight()
        // ⚠️ THE WHOLE CORPUS. These are the PLACE's numbers, and a check-in
        // with no photograph is still something that happened here. As many
        // as are loaded: the pins, and the pages read so far.
        let corpus = self.corpus
        likesTotal = Self.aggregatedLikes(of: corpus)
        headerContent.counterValues = [rank?.positionText, CountFormatter.compactString(for: likesTotal)]
        applyHeaderContent()
    }

    /// The place's next page, once the pins have landed, one at a time: its
    /// new posts appended in place, a failure retried on the next approach.
    /// Internal, not private, for the tests that page a place.
    func loadMorePosts() {
        guard let loadMore, moreLoad == nil, renderedMembers != nil else { return }
        let token: String?
        switch moreCursor {
        case .exhausted: return
        case .start: token = nil
        case .token(let next): token = next
        }
        activityPage.setPaging(true)
        moreLoad = Task { [weak self] in
            let answer = try? await loadMore(token)
            guard let self, !Task.isCancelled else { return }
            moreLoad = nil
            activityPage.setPaging(false)
            // Whatever the answer, a feed waiting on the next page hears it.
            defer { feedContinuation.answered() }
            guard let answer else {
                // Nothing on screen to keep (a page opened alone): say it.
                if corpus.isEmpty { activityPage.render(.failed(message: "Couldn't load this place's posts.")) }
                if (renderedMembers ?? []).isEmpty, extraPosts.isEmpty { endBannerWait() }
                return
            }
            moreCursor = answer.nextPageToken.map(MoreCursor.token) ?? .exhausted
            let known = Set((renderedMembers ?? []).map(\.id) + extraPosts.map(\.id))
            var seen = known
            let fresh = answer.posts.filter { seen.insert($0.id).inserted }
            extraPosts += fresh
            if fresh.isEmpty {
                emptyPagesInARow += 1
            } else {
                emptyPagesInARow = 0
            }
            // A page that ended the place re-plans the tail; one that brought
            // posts appends them. Neither moves a tile already shown.
            if !fresh.isEmpty || !hasMorePosts { renderCorpus(reset: false) }
            // No pins to lead the banner (a page opened alone): the first
            // page's top post does — and the first page, landing under a
            // header that grew with it, starts the list at its top.
            if (renderedMembers ?? []).isEmpty, !fresh.isEmpty {
                renderBanner(for: Self.bannerPost(in: Self.gallery(extraPosts)), shows: Self.showsBanner(for: extraPosts))
                if extraPosts.count == fresh.count, view.window != nil { activityPage.restAtTop() }
            } else if (renderedMembers ?? []).isEmpty, extraPosts.isEmpty,
                      !hasMorePosts || emptyPagesInARow >= Self.maxEmptyPagesInARow {
                // The place ran out with no post at all, or the pages stopped
                // being asked for: no banner is coming.
                endBannerWait()
            }
            // Nothing new but more behind: no row reaches the end to ask, so
            // the next page is asked now — a few times, not forever.
            if fresh.isEmpty, hasMorePosts, emptyPagesInARow < Self.maxEmptyPagesInARow {
                loadMorePosts()
            } else if fresh.isEmpty, hasMorePosts, corpus.isEmpty {
                // Empty pages ran out with nothing shown: the empty state,
                // not a skeleton for ever.
                renderCorpus(reset: false)
            }
        }
    }

    /// The banner wears the TOP media post's cover, as a profile's band card
    /// (`HeroHeaderView`, #1656).
    ///
    /// ⚠️ NO BANNER WHEN THE TOP POST IS WORDS (#1599, the owner 2026-10-22):
    /// the place's most popular post is a text-only one, so the page shows no
    /// picture at all — not the photograph of a post that is not its best —
    /// and the header is a bannerless profile's. A refresh whose top post
    /// kept its cover keeps the picture on screen.
    private func renderBanner(for post: GalleryPost?, shows: Bool) {
        let url = shows ? post?.thumbnailURL : nil
        let showsChanged = shows != showsBanner
        showsBanner = shows
        let wasPending = headerContent.bannerPending
        headerContent.bannerPending = false
        guard url != headerContent.bannerImageURL || wasPending else { return }
        headerContent.bannerImageURL = url
        applyHeaderContent()
        // The header changed height: the list starts again at its top, under
        // the new header (never while the viewer is moving it).
        guard showsChanged, isViewLoaded else { return }
        view.setNeedsLayout()
        view.layoutIfNeeded()
        activityPage.restAtTop()
    }

    /// The posts settled with no banner to show (failed, or none at all):
    /// the banner's skeleton leaves for the bannerless layout.
    private func endBannerWait() {
        guard headerContent.bannerPending else { return }
        headerContent.bannerPending = false
        applyHeaderContent()
    }

    // MARK: - The page's pure rules (tested directly)

    /// The profile's ordering — Discover's AND Activity's: POPULARITY
    /// descending, which on this page means REACTIONS — the place leads
    /// with what it is known for, not what happened last. The trending rule
    /// verbatim (reactions, then recency, then id, so ties are stable),
    /// applied HERE so the screen owns its ordering contract. Client-side
    /// because no ranking RPC exists (`dev/BACKEND_GAPS.md` §14/§18); it
    /// matches the map above by construction — the cluster's pin wears its
    /// most-liked member's face, which is this page's banner AND its first
    /// Gallery tile.
    static func ranked(_ posts: [GalleryPost]) -> [GalleryPost] {
        DiscoverySource.trending.ordering(posts)
    }

    /// Discover's corpus: the ranking, minus what a GRID cannot draw.
    ///
    /// ⚠️ MEDIA ONLY (product call). A text post has no cover, so as a tile it
    /// is a coloured rectangle with a caption at a size nobody reads — and this
    /// grid is the place's shop window. Its words are not lost: Activity shows
    /// every kind, as cards, at a size where they are the point.
    ///
    /// Kept as a filter over `ranked` rather than a filter at the source,
    /// because the ORDER is the same contract either way — and because the
    /// numbers and the Activity column are still drawn from the whole corpus.
    static func gallery(_ posts: [GalleryPost]) -> [GalleryPost] {
        ranked(posts).filter { $0.kind != .text }
    }

    /// The banner's subject: the top post of the GALLERY — "the previous
    /// cycle's top post" once cycles exist on the wire; until then the
    /// highest-engagement member IS the standing cycle winner.
    ///
    /// ⚠️ Asked of the gallery rather than of the whole corpus, so that the
    /// three faces this page and the map show for one place stay the same
    /// picture: the cluster's pin wears its most-liked MEDIA member, which is
    /// this banner and Discover's first tile. Passed the full corpus instead,
    /// a place whose loudest post is a check-in would show a neutral banner
    /// over a grid whose first tile is the photograph the pin is wearing.
    static func bannerPost(in ranked: [GalleryPost]) -> GalleryPost? {
        ranked.first
    }

    /// The post a close from the map put at the head of Recent
    /// (`activityCardRevealOrigin`), kept there by every later render.
    private var landedHead: GalleryPost?

    /// Everything loaded: the pins, then the pages read so far.
    private var corpus: [GalleryPost] { (renderedMembers ?? []) + extraPosts }

    /// The Popular row: the place's most liked posts — `ranked`, the rule
    /// the banner and the map's pin already lead with — every kind, the first
    /// `limit` (all of them for the pushed list).
    /// The Popular shelf over `corpus` (the shelf contract, #1671): the
    /// `popularRowCount` most liked posts, its rows ending on "View all" only
    /// when the Popular list holds more than those — a place with three
    /// posts shows three, and no chevron.
    static func popularShelf(_ corpus: [GalleryPost]) -> PostShelfSection.Model {
        let ranked = popular(corpus, limit: nil)
        return PostShelfSection.Model(
            title: "Popular",
            posts: Array(ranked.prefix(popularRowCount)),
            hasMore: ranked.count > popularRowCount
        )
    }

    static func popular(_ posts: [GalleryPost], limit: Int?) -> [GalleryPost] {
        let ordered = ranked(posts)
        return limit.map { Array(ordered.prefix($0)) } ?? ordered
    }

    /// How much a day of age weighs against engagement in `recent`.
    static let recentDayWeight = 0.5

    /// The Recent list: a light For You rule rather than a strict date order
    /// (the owner, 2026-10-16 — a For You in disguise, not called one).
    /// Engagement (likes, comments counted twice) on a log scale, less half a
    /// point per day older than the place's newest post: a post a few days
    /// old with far more engagement climbs over yesterday's quiet one, a week
    /// old needs a great deal. Ties go to the newer, then the id, so the
    /// order is stable.
    static func recent(_ posts: [GalleryPost]) -> [GalleryPost] {
        guard let newest = posts.map(\.publishedAtMS).max() else { return [] }
        func score(_ post: GalleryPost) -> Double {
            let ageDays = Double(newest - post.publishedAtMS) / 86_400_000
            let engagement = log1p(Double(post.reactionCount ?? 0) + 2 * Double(post.commentCount ?? 0))
            return engagement - ageDays * recentDayWeight
        }
        return posts.map { ($0, score($0)) }.sorted { lhs, rhs in
            if lhs.1 != rhs.1 { return lhs.1 > rhs.1 }
            if lhs.0.publishedAtMS != rhs.0.publishedAtMS { return lhs.0.publishedAtMS > rhs.0.publishedAtMS }
            return lhs.0.id.rawValue < rhs.0.id.rawValue
        }.map(\.0)
    }

    /// The place's likes: every member's, summed — client-side, since
    /// counter.v1 has no place entity to ask (`dev/BACKEND_GAPS.md`). Missing
    /// values count as zero rather than poisoning the sum — a counter the
    /// read-model never projected is absence, not information.
    static func aggregatedLikes(of posts: [GalleryPost]) -> Int64 {
        posts.reduce(0) { $0 + ($1.reactionCount ?? 0) }
    }

    /// The Recent list as rendered — for the tests that pin its order
    /// without reaching into the page.
    var renderedActivity: [GalleryPost] { activityPage.posts }
    /// The Popular row as rendered, same purpose.
    var renderedPopular: [GalleryPost] { shelf.cards }

    // MARK: - The navigation bar

    /// The bar, left to right: back chevron · selector (docked only) ·
    /// dynamic space · points balance. The star and the QR code are the row
    /// under the identity again (#1598).
    private func configureNavigationItems() {
        configureActionRow()
        configureWalletBadge()
        applyTrailingItems()
    }

    /// ⚠️ IN ITS OWN BUBBLE: `sharesBackground = false` (#1304).
    private func applyTrailingItems() {
        let items = [walletItem].compactMap { $0 }
        for item in items { item.sharesBackground = false }
        // Through the toasts' door (#1420, #1679).
        setOwnTrailingBarItems(items, animated: false)
    }

    /// The viewer's spendable points, in the toolbar — the fifth host of one
    /// badge (the map, For You, the profile, the post screen, and here).
    ///
    /// Built in this package rather than through the shell's
    /// `WalletBadgeInstaller`, for the reason the post screen is: a pushed
    /// screen owns its own navigation item, and what the installer exists to
    /// share — the freshness rules — is two closures here.
    private func configureWalletBadge() {
        guard let wallet, showsBalance else { return }
        // A badge with no sheet behind it is a read-out, not a control.
        walletBadge.isUserInteractionEnabled = makeWalletSheet != nil
        walletBadge.addAction(
            UIAction { [weak self] _ in
                guard let self, let sheet = self.makeWalletSheet?() else { return }
                self.present(sheet, animated: true)
            },
            for: .primaryActionTriggered
        )
        // ⚠️ A GROWN COUNT NEEDS A FRESH WRAPPER. Re-assigning the same item
        // hands the bar the same wrapper at the same frozen size (measured on
        // the post screen: "120" still came back wrapped), so a new item is
        // the only thing a bar measures anew.
        walletBadge.onFittedWidthChange = { [weak self] in
            guard let self else { return }
            self.walletItem = self.makeWalletItem()
            self.applyTrailingItems()
        }
        walletItem = makeWalletItem()
        refreshWalletBadge()
        // Spends and claims wherever they happen — a boost in the feed pushed
        // over this page, a claim taken on the map beneath it.
        walletObservers.add(NotificationCenter.default.addObserver(
            forName: WalletStore.didChangeNotification, object: wallet, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshWalletBadge() }
        })
    }

    private func makeWalletItem() -> UIBarButtonItem {
        let item = BarItems.container(id: BarItems.SharedID.walletBalance, view: walletBadge)
        item.accessibilityLabel = "Likes balance"
        return item
    }

    private func refreshWalletBadge() {
        guard let wallet else { return }
        let snapshot = wallet.snapshot()
        walletBadge.update(
            balance: snapshot.balance,
            // A badge with no sheet to open must not advertise a claim the
            // viewer has no way to take from here.
            claimAvailable: makeWalletSheet != nil && snapshot.claimAvailable,
            claimProgress: snapshot.claimCountdown.map {
                WalletBadgeButton.ClaimProgress(fraction: $0.fraction, remaining: $0.remaining)
            }
        )
    }

    /// The row's star: following a place pins it to the map's "pinned"
    /// filter (the same store).
    private func starTapped() {
        MemberGates.perform(.followPlace, from: self) { [weak self] in
            guard let self, let following = self.following else { return }
            self.renderFollowState(following.toggle(), animated: true)
        }
    }

    /// The star's two states: outline while the viewer does not follow the
    /// place, filled in the save star's gold once they do (`SaveStar`).
    private func renderFollowState(_ isFollowing: Bool, animated: Bool) {
        followState = isFollowing
        starButton.setContent(.symbol(SaveStar.symbol(saved: isFollowing)), animated: animated)
        starButton.inkColor = isFollowing ? SaveStar.tint : nil
        starButton.accessibilityLabel = isFollowing ? "Unfollow this place" : "Follow this place"
    }

    // MARK: - Opening a tile

    private func openTile(
        at index: Int, in grid: ForYouGridPage?, showingComments: Bool = false
    ) {
        // One opening at a time — before anything below claims the tile.
        guard let grid,
              navigationController.map({ FeedFeatureBuilder.canOpen(from: self, on: $0) }) ?? true
        else { return }
        let posts = grid.posts
        guard posts.indices.contains(index) else { return }
        let tapped = posts[index]
        let stream = Array(posts[index...].prefix(Self.seedWindow))
        // On past the window into the place's next pages (#643); nil when
        // the pins are the whole place.
        var continuation: SnapFeedContinuation?
        if loadMore != nil {
            continuation = { [weak self] after in await self?.feedContinuation.postIDs(after: after) }
        }
        // ⚠️ THE ONE TILE CONTRACT (#1270, epic #1269): the page describes its
        // tile — take-off playing, the playhead continued on a same-post
        // close, the tile's own parked clip after paging on, the words faded
        // in on a close. Closed by `viewDidAppear`'s `endPlaybackHandoff`.
        let origin = grid.heroOrigin(
            opening: tapped, stream: stream, in: view,
            // A row with no media has nothing to fly; this is the window every
            // other list gives a text post.
            textReveal: textRowReveal(for: tapped, in: grid),
            // A TEXT post's page IS its thread — see `opensComments`.
            opensComments: showingComments && tapped.kind != .text,
            // This page manages its own freeze (`clearLandingConcealment`).
            pinsBeforeClose: false,
            continuation: continuation
        )
        continuationGrid = grid
        // Remembered for the CLOSE. A flight opened from this page has a tile
        // to go home to, which is exactly what tells that close apart from the
        // map's Case B — see `cardCloseGeometry`. Cleared when this page is the
        // screen again (`viewDidAppear`), so a stale departure can never answer
        // for a later flight that came from somewhere else.
        departure = .list(tapped.id)
        openPost(self, origin, stream.map(\.id))
    }

    /// Which posts on this screen are even CANDIDATES for a window.
    ///
    /// Pure and apart from the view for the reason the other two rules on this
    /// screen are: both ways of getting it wrong are silent. A media row handed
    /// a window would open a card onto a photograph the card does not draw; a
    /// text row denied one keeps the plain push, which is a perfectly good
    /// slide and looks like nothing is broken — which is exactly how it went
    /// unnoticed on this surface in the first place.
    ///
    /// `onListTab` rather than "which tab is up": Discover is a GRID, whose
    /// text posts are tiles with no caption to open out of, and a future third
    /// tab must not inherit a window by sitting at the right index.
    static func textWindowIsAvailable(for post: GalleryPost, onListTab: Bool) -> Bool {
        onListTab && post.kind == .text
    }

    /// The window a TEXT row opens through, or nil for anything that is not
    /// one — which keeps the plain push as the honest floor.
    ///
    /// Only the Activity tab can produce one: it is the `.list` page, and
    /// Discover is `.grid`, whose text posts are tiles with no caption to open
    /// out of. Asked of the page that was actually tapped rather than assumed,
    /// so a future third tab cannot inherit a window it cannot draw.
    ///
    /// ⚠️ MARKER-SHAPED, not row-shaped, and that is a deliberate trade. A
    /// row's caption normally lets the window align the page to it — the
    /// effect that reads as the card growing — but that alignment is only
    /// honest while the row and the page are the SAME post, and this feed is a
    /// PAGER. So the window takes the same answers the map's marker takes
    /// (`alignsPageToSource: false`, no cut, no borrowed band): the page holds
    /// still and the card opens over it. Never mis-aimed, at the cost of the
    /// growth effect.
    ///
    /// ⚠️ IT LANDS ON THE POST THE VIEWER TAPPED, always — even several pages
    /// on, even onto a photograph.
    ///
    /// This was briefly re-pointed at the settled post, on the reasoning that a
    /// window opened from WORDS has nothing a text row can receive once the
    /// viewer is on a picture. That reasoning was answering the wrong
    /// complaint. What made a paged close look like no animation at all was a
    /// forwarded pop returning nil and stranding the grab
    /// (`InteractiveSlideDismissal`'s decline rule); with that fixed the window
    /// runs either way, and re-pointing bought nothing but a list that appeared
    /// to shuffle. A scroll is not a reorder in the code and IS one to the eye:
    /// the post that was under the card is replaced by another, which is
    /// exactly what the product rule for this ranked tab forbids.
    ///
    /// So the fade is the answer, and the machinery already gives it:
    /// `RevealStage.swapFractions` puts an empty beat between the page and the
    /// card, so the departing media dissolves out and the original's words
    /// dissolve in with nothing drawn over anything. That beat is also why this
    /// is legal at all — neither half of the fade ever has text on both sides.
    private func textRowReveal(
        for post: GalleryPost, in grid: ForYouGridPage
    ) -> TextRevealOrigin? {
        // ⚠️ THE MODEL SAYS WHAT THE POST IS, the page only says whether it can
        // be described. Asking `heroAppearance` for the first half conflates
        // "has no media" with "has no realized cell", and an off-screen MEDIA
        // row would answer the same as a text one. The rect stays a question
        // for the page — a window needs somewhere to open from, and nil there
        // is the documented plain-push floor.
        guard Self.textWindowIsAvailable(for: post, onListTab: grid === activityPage),
              grid.rowFrame(for: post.id, in: grid) != nil
        else { return nil }
        let anchor = post.id
        // A TILE of the list's mosaic (or a paired card) opens through its
        // own window — its shape and ground, nothing to align.
        if grid.drawsAsTile(anchor) {
            return grid.tileWindow(
                for: post,
                willStageDismissal: { [weak self] in
                    guard let self else { return }
                    view.layoutIfNeeded()
                    activityPage.beginHeroFreeze()
                    activityPage.revealPost(anchor, clearing: landingOcclusion)
                    view.layoutIfNeeded()
                },
                dismissalDidEnd: { [weak self] committed in
                    guard let self else { return }
                    activityPage.endHeroFreeze()
                    if !committed { activityPage.clearRevealConcealment() }
                }
            )
        }
        return TextRevealOrigin(
            rowFrame: { [weak self] space in
                guard let self else { return nil }
                return activityPage.textRowFrame(for: anchor, in: space)
                    ?? activityPage.rowFrame(for: anchor, in: space)
            },
            captionEnd: nil,
            depthView: { [weak self] in self?.activityPage },
            makeDismissStandIn: { [weak self] _ in
                // The settled post is deliberately ignored: this window closes
                // onto the row it opened from, whatever the viewer paged to.
                self?.activityPage.makeDismissStandIn(for: anchor)
            },
            alignsPageToSource: false,
            // ⚠️ THE PAGE FILLS THE WINDOW — see `RevealPageFit.covering`.
            //
            // Held still it stayed at full size while the window shrank around
            // it: a keyhole panning over a photograph, filmed on this screen.
            // It fitted INSIDE the window for a while instead, which stopped
            // the truncation and started the other half of it — on the release
            // spring, where the window's aspect leaves the page's, the media
            // sat letterboxed with the card's ground above and below it.
            // Filmed too.
            //
            // The invariant every report has agreed on is the simple one: the
            // media fills the transition window, always. That is covering, and
            // it is what the marker has used all along.
            pageFit: .covering,
            setConcealed: { [weak self] concealed in
                self?.activityPage.setRevealConcealed(concealed, for: anchor)
            },
            // The row may have scrolled away under the open post — a hydration
            // or an engagement decoration re-realizes this list — and an
            // unrealized row answers nil for its rect, which sends the window
            // to a centred fallback that on screen is indistinguishable from a
            // working close. Bringing it back is all this does; the SETTLED
            // post is deliberately unused, see the note above.
            willStageDismissal: { [weak self] _ in
                guard let self else { return }
                view.layoutIfNeeded()
                activityPage.beginHeroFreeze()
                activityPage.revealPost(anchor, clearing: landingOcclusion)
                view.layoutIfNeeded()
            },
            dismissalDidEnd: { [weak self] committed in
                guard let self else { return }
                activityPage.endHeroFreeze()
                if !committed { activityPage.clearRevealConcealment() }
            }
        )
    }
}

// MARK: - The close from the map's feed

/// What a post closes onto when its feed was opened by a FLIGHT from the map.
///
/// ⚠️ THE PRESENTATION WAS CHOSEN AT THE TAP, and the feed is a pager: a
/// media-faced marker opens with a hero, and the viewer may be on any post by
/// the time they close. The map attaches a card-shaped driver alongside the
/// flight (`attachCardCloseAlongsideFlight`) and asks this screen where to
/// land it — and DOWNWARD it is that driver's close for every post, media
/// included, because this page refuses a hero (`zoomLandingAcceptsHero`).
///
/// ⚠️ THE LANDING DOES NOT DEPEND ON THE MARKER'S KIND. It used to: a text
/// marker's feed (a reveal, `FeedFeatureBuilder.pushWithoutFlight`) closed
/// onto the Activity tab with the post on screen moved to its top, while a
/// media marker's feed flew onto the FIRST DISCOVER TILE — two tabs for one
/// gesture, chosen by what the marker happened to wear (filmed: Paris, a text
/// marker, right; Lyon, a music clip, wrong). Both now go through
/// `activityCardRevealOrigin(sizedTo:settled:)`.
///
/// ⚠️ THERE IS NO DEPARTURE ROW HERE, which is what makes the head of the
/// list the honest landing. For You's version of this close departs FROM a
/// row and lands back on it; this flight departed from a map marker onto a
/// page that has never been seen, so there is nowhere on it the viewer was.
/// The close puts what they were reading first and lands there.
extension PlaceProfileViewController: CardCloseLanding {
    func cardCloseGeometry(dismissing feed: UIViewController) -> RevealGeometry? {
        // A flight that left THIS page has a tile to go back to. Answered
        // first, because it is the case with somewhere the viewer actually was
        // — everything below is for the flight that arrived from a marker.
        switch departure {
        case .list(let id):
            return tileCardCloseGeometry(dismissing: feed, departing: id)
        case .card(let origin):
            // Home to the Popular card it left, through the window its
            // origin described.
            return TextRevealInstaller.geometry(feed: feed, origin: origin, pipeline: imagePipeline)
        case nil:
            break
        }
        // Measured in the bounds the pop will run in: this page is off-stack
        // and unsized when the driver asks, and the feed's own stack is the
        // one it is about to join.
        let bounds = feed.navigationController?.view.bounds ?? feed.view.bounds
        // …under the feed's own chrome, which this page is about to wear.
        stagingChromeTop = feed.navigationController?.navigationBar.frame.maxY ?? feed.view.safeAreaInsets.top
        // ⚠️ HOME TO POPULAR'S FIRST CARD (#1596, the owner 2026-10-22): a
        // flight that arrived from a MARKER lands on the page's FIRST section
        // — the place's most popular post — and never re-plans Recent to put
        // the post read at its head (the old rule, kept below as the fallback
        // for a page with no Popular card).
        guard let origin = markerFlightLandingOrigin(sizedTo: bounds, settled: activePostID?()) else { return nil }
        return TextRevealInstaller.geometry(feed: feed, origin: origin, pipeline: imagePipeline)
    }

    /// Where a post opened from a MARKER lands when it closes down onto this
    /// page — the one rule for every such close, a hero's (`cardCloseGeometry`)
    /// and a text post's (the feed builder's reveal close): Popular's first
    /// card of the post's kind (#1596), else, with no Popular card, the head
    /// of Recent with the post put there.
    ///
    /// ⚠️ ONE RULE, TWO CALLERS (the owner, on device, 2026-10-23): #1596
    /// changed only the hero's close, and a TEXT post opened from a text
    /// marker still landed at the head of Recent — the other caller asked
    /// `activityCardRevealOrigin` directly.
    func markerFlightLandingOrigin(sizedTo bounds: CGRect, settled: PostID?) -> TextRevealOrigin? {
        if let origin = popularLandingOrigin(sizedTo: bounds, closing: settled) {
            debugLogLanding("landing on Popular's first card of the post's kind")
            return origin
        }
        guard let settled else { return nil }
        debugLogLanding("landing \(settled.rawValue) at the head of Recent")
        return activityCardRevealOrigin(sizedTo: bounds, settled: settled)
    }

    /// The window onto Popular's first card OF THE CLOSING POST'S KIND, with
    /// the page staged at its top so the shelf is on screen: the card's own
    /// window — the one its flight left by (`PostShelfOrigins`), a media
    /// card's or a text card's. Nil when the shelf has no card.
    ///
    /// ⚠️ BY KIND (the owner, 2026-10-22): a text post closes onto the first
    /// card of Popular's TEXT row, a media post onto the first of its MEDIA
    /// row — "le premier item de leur type de contenu dans la première
    /// section". The shelf's first card alone sent a text post's close onto a
    /// photograph. Any card when the shelf has none of that kind.
    func popularLandingOrigin(sizedTo bounds: CGRect, closing closingID: PostID? = nil) -> TextRevealOrigin? {
        loadViewIfNeeded()
        let closingIsText = closingID.flatMap { id in corpus.first { $0.id == id } }.map { $0.kind == .text }
        let sameKind = closingIsText.flatMap { isText in shelf.cards.first { ($0.kind == .text) == isText } }
        guard let first = sameKind ?? shelf.cards.first else { return nil }
        let stage: () -> Void = { [weak self] in
            guard let self else { return }
            if view.bounds.size != bounds.size, bounds.size != .zero { view.frame = bounds }
            view.layoutIfNeeded()
            activityPage.restAtTop()
            view.layoutIfNeeded()
        }
        stage()
        guard shelf.cardFrame(for: first.id, in: shelf) != nil else {
            debugLogLanding("no realized Popular card for \(first.id.rawValue)")
            return nil
        }
        return first.kind == .text
            ? PostShelfOrigins.textCardReveal(for: first, shelf: shelf, page: activityPage, closeStaged: stage)
            : PostShelfOrigins.cardReveal(
                for: first, cover: shelf.cardCover(for: first.id), shelf: shelf, page: activityPage, closeStaged: stage
            )
    }

    func clearLandingConcealment() {
        // BOTH channels, on BOTH pages: the flight hid the departure at the
        // push and only its own return puts that back, so a visit that ends on
        // a text post — closed by the card driver — would leave it blank. Which
        // page held it depends on which tab the viewer opened from, and by the
        // time this runs that is no longer a question worth asking.
        for hosted in hostedPages {
            let grid = hosted
            grid.clearRevealConcealment()
            grid.clearHeroConcealment()
            grid.endHeroFreeze()
        }
        shelf.clearConcealments()
    }

    /// The close for a flight this page itself opened: home to the very tile
    /// the viewer tapped, on the tab they tapped it on.
    ///
    /// ⚠️ NO SUBSTITUTION, and that is the whole difference from the sibling
    /// above. That one departed from a MAP MARKER onto a grid the viewer has
    /// never seen, so it is free to pick the nearest landable tile — there is
    /// no "where they were" to honour. Here there is one, they chose it, and
    /// the product rule for this screen is that the arrival is always the post
    /// the flight opened. A ranked list is also not free to be re-pointed into.
    ///
    /// ⚠️ THE FLIGHT'S CONCEALMENT COMES OFF FIRST, before anything is
    /// measured. The push hid the departure through the HERO channel
    /// (`setHeroHidden`), and only the flight's own return leg pays that back —
    /// a return this close is replacing. Left alone the window shrinks onto a
    /// hole, and the restore must land a beat BEFORE the window retires, never
    /// after: at the landing rect the cell and the window are identical, so
    /// swapping them inside one transaction is invisible while doing it in two
    /// is a flash of empty grid.
    ///
    /// The REVEAL's own channel then takes over and hides the same cell for the
    /// length of the close, which is what stops it showing beside the window.
    /// (That channel used to resolve a list-row cell only, so on the Discover
    /// grid both its hide and its restore landed on nothing — fixed in
    /// `setRevealConcealed`, which now switches on the cell like the hero
    /// channel beside it always has.)
    private func tileCardCloseGeometry(
        dismissing feed: UIViewController, departing anchor: PostID
    ) -> RevealGeometry? {
        let grid = activityPage
        grid.clearHeroConcealment()
        stageActivityLanding(for: anchor, sizedTo: nil)
        guard let post = grid.post(for: anchor),
              grid.rowFrame(for: anchor, in: grid) != nil
        else {
            debugLogLanding("no realized departure for \(anchor.rawValue)")
            return nil
        }
        debugLogLanding("landing on its own departure \(anchor.rawValue)")
        let staged: () -> Void = { [weak self] in
            guard let self else { return }
            // And again, for the same reason: the pass that SETS an offset
            // does not realize the cells at it.
            activityPage.clearHeroConcealment()
            stageActivityLanding(for: anchor, sizedTo: nil)
        }
        let ended: (Bool) -> Void = { [weak self] committed in
            guard let self else { return }
            activityPage.endHeroFreeze()
            if !committed { activityPage.clearRevealConcealment() }
        }
        // A mosaic TILE (or a paired card) closes as its own window — its
        // shape, its ground, its corner.
        let origin: TextRevealOrigin
        if grid.drawsAsTile(anchor),
           let window = grid.tileWindow(for: post, willStageDismissal: staged, dismissalDidEnd: ended) {
            origin = window
        } else {
            origin = TextRevealOrigin(
                rowFrame: { [weak self] space in self?.activityPage.rowFrame(for: anchor, in: space) },
                // No cut: a row's caption belongs to the DEPARTURE post while
                // the page being closed may be showing a different one.
                captionEnd: nil,
                depthView: { [weak self] in self?.activityPage },
                makeDismissStandIn: { [weak self] _ in
                    // The settled post is deliberately ignored — this window
                    // closes onto what the viewer opened.
                    self?.activityPage.makeDismissStandIn(for: anchor)
                },
                // ⚠️ FALSE: a caption measured on one post cannot align a
                // page showing another.
                alignsPageToSource: false,
                // The media fills the window, always — `RevealPageFit.covering`.
                pageFit: .covering,
                fill: PostGridListRowCell.cardFillColor,
                setConcealed: { [weak self] concealed in
                    self?.activityPage.setRevealConcealed(concealed, for: anchor)
                },
                willStageDismissal: { _ in staged() },
                dismissalDidEnd: ended
            )
        }
        return TextRevealInstaller.geometry(feed: feed, origin: origin, pipeline: imagePipeline)
    }
}

// MARK: - The registered intermediate that refuses a flight

/// ⚠️ A `ZoomTransitionSource` THAT NEVER RECEIVES A FLIGHT, and it is both on
/// purpose.
///
/// The map registers this page as its flight's intermediate
/// (`ZoomTransitionController.setDismissSource`), and that registration is how
/// it hears a dismissal LANDED here rather than on the map
/// (`onDismissedToIntermediate`: the lock released, the marker un-hidden). The
/// registration takes a source, so this page is one.
///
/// It used to be a real one: a photograph's downward grab flew its card onto
/// the first DISCOVER tile, so a media marker's feed closed onto a different
/// tab from a text marker's (see `cardCloseGeometry`). Every downward close is
/// now the card close onto the Activity row, and `zoomLandingAcceptsHero` is
/// the refusal that makes it so — asked by the hero grab AND by the map's card
/// driver (`heroClaimsAxis`), so exactly one of them claims the drag. The
/// members below are the protocol's floor and nothing more: no grab begins
/// against this source, so none of them is ever asked to draw.
extension PlaceProfileViewController: ZoomTransitionSource {
    var zoomLandingAcceptsHero: Bool { false }

    func zoomHeroFrame(in container: UICoordinateSpace) -> CGRect {
        ZoomTransitionGeometry.centeredFallback(in: container.bounds, side: 96)
    }

    var zoomSourceIsOnScreen: Bool { false }

    func makeZoomFlightCard() -> any ZoomFlightCard {
        PostGridFlightCard(post: Self.placeholder(id: PostID("")), cover: nil, style: .tile)
    }

    func setZoomSourceHidden(_ hidden: Bool) {}

    /// ⚠️ DECLARED, because both protocols default it and this page conforms
    /// to both (the map return below makes it a DESTINATION): with two
    /// defaults and no member, the conformance is ambiguous. Nothing to adopt
    /// on either side — no flight lands here as a source, and as a destination
    /// this page is never PRESENTED by a zoom (it is spliced into the stack),
    /// which is the only leg that hands a destination the surface.
    func zoomAdoptLiveMediaView(_ view: UIView) {}
}

extension PlaceProfileViewController {
    // MARK: - The Activity card every downward close lands on

    /// Where a cluster feed's DOWNWARD close goes home, whichever route opened
    /// it (a text marker's reveal, a media marker's flight — see
    /// `cardCloseGeometry`): the post's own CARD at the head of the Activity
    /// tab, described as a reveal origin.
    ///
    /// ⚠️ A REVEAL, NOT A HERO FLIGHT, for a photograph too. The window carries
    /// the whole page into the row (`RevealPageFit.covering`), which lands a
    /// clip on its card exactly as it lands words on theirs; one close for
    /// every post is what makes the page arrive the same way whatever the
    /// marker wore. For a text post there was never a choice: the zoom stack
    /// refuses it three separate ways — the hero grab
    /// declines a `.card` dismissal outright, the slide forwards to a flight
    /// delegate only for `.hero`, and the one flight card this feature owns
    /// (`PostGridFlightCard`) has no style that can carry a caption, so it
    /// would fly a blank rounded rect. That is precisely the
    /// "hero animation about nothing" this codebase already rejected once for
    /// the map's text markers. The reveal's stand-in is a REAL
    /// `PostGridListRowCell` carrying this post's own words, author and age,
    /// floating free under the finger — the card morph, with nothing
    /// impersonated.
    ///
    /// Returns nil when the Activity tab has no card for the post, which is
    /// what selects the plain-slide fallback.
    ///
    /// ⚠️ IT STAGES BEFORE IT MEASURES, and it has to. A `RevealGeometry`
    /// takes the caption's cut, the caption's top and the author band as
    /// VALUES — read the moment it is built — while only the rect is a
    /// closure the transition re-asks later. This page is off-stack and
    /// unsized when the driver asks, so its cards do not exist yet and every
    /// one of those numbers would be zero. `sizedTo` is the bar the caller
    /// measures in; giving the view that size and laying it out is what makes
    /// the row real enough to describe.
    func activityCardRevealOrigin(
        sizedTo bounds: CGRect, settled: PostID? = nil
    ) -> TextRevealOrigin? {
        // ⚠️ THE FIRST ROW, whatever the viewer paged to: this list arrived
        // from a MARKER, the viewer has never seen it, so there is nowhere on
        // it they were — and a page put down scrolled to an arbitrary row
        // hides everything above it.
        //
        // ⚠️ Settled BEFORE anything is measured, because every caption field
        // below is read as a VALUE off this row.
        // ⚠️ THE POST THE VIEWER IS ON BECOMES THE FIRST ONE, and the close
        // lands there.
        //
        // This is the ONE landing that is allowed to move a list, and it is a
        // product rule rather than a transition one: a post opened from the MAP
        // has no row to go back to — the place page it lands in was never on
        // screen — so the close puts what they were reading at the top of the
        // list and returns it there. Everywhere else a close lands on the post
        // that opened it and the order is untouched.
        //
        // Swapped when the list already holds it, inserted at the head when it
        // does not. Either way the anchor is slot zero afterwards.
        var anchor = activityPage.posts.first?.id ?? anchorID
        guard activityPage.post(for: anchor) != nil else {
            debugLogLanding("no post for \(anchor.rawValue)")
            return nil
        }
        // ⚠️ A RE-RENDER, NOT A SWAP: the list is For You's (`.discover`),
        // whose stretches are planned, and a post is never moved behind the
        // planner's back. The page is under the feed and has never
        // been seen, so it is re-planned with the post first — the one landing
        // allowed to move the list.
        if let settled, settled != anchor,
           let model = activityPage.post(for: settled) ?? corpus.first(where: { $0.id == settled }) {
            let reordered = [model] + activityPage.posts.filter { $0.id != settled }
            landedHead = model
            activityPage.invalidateIncrementalUpdates()
            activityPage.render(.content(reordered))
            anchor = settled
        }
        anchorID = anchor
        stageActivityLanding(for: anchor, sizedTo: bounds)
        // Nothing to describe — no cell for this post even after staging.
        guard activityPage.rowFrame(for: anchor, in: activityPage) != nil else {
            debugLogLanding("no realized row for \(anchor.rawValue)"
                + " bounds=\(view.bounds.size) posts=\(activityPage.posts.count)")
            return nil
        }
        debugLogLanding("staged \(anchor.rawValue)"
            + " row=\(activityPage.rowFrame(for: anchor, in: activityPage).map(\.debugDescription) ?? "nil")")
        // The head of Recent may be a mosaic TILE (or a paired card): it
        // takes its own window, in its own shape and ground.
        if activityPage.drawsAsTile(anchor), let post = activityPage.post(for: anchor) {
            return activityPage.tileWindow(
                for: post,
                willStageDismissal: { [weak self] in self?.stageActivityLanding(for: anchor, sizedTo: nil) },
                dismissalDidEnd: { [weak self] committed in
                    guard let self else { return }
                    activityPage.endHeroFreeze()
                    if !committed { activityPage.clearRevealConcealment() }
                }
            )
        }
        return TextRevealOrigin(
            rowFrame: { [weak self] space in
                guard let self else { return nil }
                // The text row's own rect, falling back to the whole row —
                // the two-step For You's own close uses, because a row that
                // carries media has no text rect to give.
                return activityPage.textRowFrame(for: anchor, in: space)
                    ?? activityPage.rowFrame(for: anchor, in: space)
            },
            captionEnd: activityPage.textRowCaptionEnd(for: anchor),
            depthView: { [weak self] in self?.activityPage },
            captionTop: activityPage.textRowCaptionTop(for: anchor),
            authorBand: activityPage.textRowAuthorBand(for: anchor),
            makeDismissStandIn: { [weak self] _ in
                self?.activityPage.makeDismissStandIn(for: anchor)
            },
            // No cornerRadius and no fill: a ROW must take the card's own
            // values (`TextRevealInstaller` reads them from PostGrid). Only a
            // map marker, which is a disc in its own tint, overrides them.
            // ⚠️ THE PAGE FILLS THE WINDOW — see `RevealPageFit.covering`.
            //
            // Held still it stayed at full size while the window shrank around
            // it: a keyhole panning over a photograph, filmed on this screen.
            // It fitted INSIDE the window for a while instead, which stopped
            // the truncation and started the other half of it — on the release
            // spring, where the window's aspect leaves the page's, the media
            // sat letterboxed with the card's ground above and below it.
            // Filmed too.
            //
            // The invariant every report has agreed on is the simple one: the
            // media fills the transition window, always. That is covering, and
            // it is what the marker has used all along.
            pageFit: .covering,
            setConcealed: { [weak self] concealed in
                // The reveal's OWN channel, never `setHeroHidden` — the two
                // conceal flags are deliberately separate.
                self?.activityPage.setRevealConcealed(concealed, for: anchor)
            },
            // Re-asserted once the page is really on the stack and sized by
            // the transition's own container: idempotent by construction, and
            // the only chance to correct anything the off-stack staging got
            // wrong about a width it had to be told.
            willStageDismissal: { [weak self] _ in
                self?.stageActivityLanding(for: anchor, sizedTo: nil)
            },
            dismissalDidEnd: { [weak self] committed in
                guard let self else { return }
                activityPage.endHeroFreeze()
                // A cancelled close leaves the row concealed under a page that
                // sprang back, and the viewer may then leave by the chevron.
                if !committed { activityPage.clearRevealConcealment() }
            }
        )
    }

    /// `-grab-log`: why a text close did or did not get its card. The two
    /// outcomes are indistinguishable on screen — a plain slide is what a
    /// refusal looks like, and it is also a perfectly good animation — so the
    /// reason has to be said out loud or a regression here is invisible.
    private func debugLogLanding(_ message: @autoclosure () -> String) {
        #if DEBUG
        guard ProcessInfo.processInfo.arguments.contains("-grab-log") else { return }
        print("[place-landing] \(message())")
        #endif
    }

    /// Puts this page on its Activity tab with `anchor`'s card on screen —
    /// the landing a text close aims at.
    ///
    /// `sizedTo` is for the off-stack call, where the view has no bounds of
    /// its own yet; pass nil once the transition's container owns the size.
    /// Idempotent: it is run once to measure and again to land.
    private func stageActivityLanding(for anchor: PostID, sizedTo bounds: CGRect?) {
        loadViewIfNeeded()
        if let bounds, view.bounds.size != bounds.size {
            view.frame = bounds
        }
        // ⚠️ LAY OUT BEFORE REVEALING, and this ordering is the whole of it.
        // `revealPost` asks the collection view for the landing row's layout
        // attributes; on a page that has only just been given a size those
        // are nil, so the scroll goes nowhere and the row is never realized —
        // measured as "no realized row" on the FIRST ask and a correct row on
        // the second, which is what made the close silently fall back to a
        // slide every time.
        view.layoutIfNeeded()
        activityPage.beginHeroFreeze()
        activityPage.revealPost(anchor, clearing: landingOcclusion)
        // And again: cells at the landed offset are realized by the pass
        // AFTER it is set, never by the one that set it.
        view.layoutIfNeeded()
    }


    /// A landing post the grid does not hold (hydration raced the grab, or
    /// the feed paged past the members somehow) still needs a card to fly —
    /// a plain dark square, which is what a missing cover renders as anyway.
    private static func placeholder(id: PostID) -> GalleryPost {
        GalleryPost(
            id: id, kind: .photo, isRepost: false, thumbnailURL: nil,
            caption: "", publishedAtMS: 0
        )
    }
}

#if DEBUG
extension PlaceProfileViewController {
    /// The header's top, from the screen's — negative while collapsed,
    /// positive under a pull-down. After a layout pass.
    var debugHeaderConstant: CGFloat {
        view.layoutIfNeeded()
        return headerHost.frame.minY
    }
    /// The dock line, as the coordinator computed it for this layout.
    var debugHeaderTravel: CGFloat { headerTravel }
    /// The detents the list rests on — the profile's (#1599, #1656).
    var debugSnapDetents: (all: [CGFloat], catching: [CGFloat]) {
        (activityPage.snapDetents, activityPage.catchDetents)
    }
    /// The identity's fade at the dock.
    var debugIdentityAlpha: CGFloat { heroHeader.alpha }
    var debugLandingOcclusion: UIEdgeInsets { landingOcclusion }
    var debugHeaderBottom: CGFloat { headerHost.frame.maxY }
    /// The hero header the page wears (#1656), for a test that reads it.
    var debugHeader: HeroHeaderView { heroHeader }
    /// What the header was last handed.
    var debugHeaderContent: HeroHeaderContent { headerContent }
    /// The flag standing in the header's disc.
    var debugFlag: UIImageView { flagView }
    /// The bar's trailing items, rightmost first (#1304).
    var debugTrailingItems: [UIBarButtonItem] { ownTrailingBarItems }
    /// The row's controls, each nil when its seam is (#1598).
    var debugStarButton: AppIconButton? { starButton.superview == nil ? nil : starButton }
    var debugQRButton: AppIconButton? { qrButton.superview == nil ? nil : qrButton }
    var debugDockPinButton: AppButton? { dockPinButton.superview == nil ? nil : dockPinButton }
    var debugActionRowFrame: CGRect { heroHeader.convert(heroHeader.debugTrayFrame, to: view) }
    var debugIsDocked: Bool { isDocked }
    /// The share sheet the QR bubble opens.
    func debugMakeShareSheet() -> ShareSheetViewController? { makeShareSheet() }
    var debugHasBannerPicture: Bool { heroHeader.debugBannerHasPicture }
    /// Drives the header the way a scroll does, which the simulator cannot.
    func debugApplyHeaderOffset(_ travelled: CGFloat) { applyHeaderOffsetNow(travelled) }
    /// The name's frame, in the view's space.
    var debugNameFrame: CGRect { heroHeader.convert(heroHeader.debugNameFrame, to: view) }
    /// The identity row — the flag and, beside it, the name over the
    /// counters — in the view's space.
    var debugIdentityFrame: CGRect {
        heroHeader.convert(heroHeader.debugAvatarFrame.union(heroHeader.debugStatsFrame), to: view)
    }
    var debugMetricsFrame: CGRect { heroHeader.convert(heroHeader.debugStatsFrame, to: view) }
    /// The Ranking as drawn — nil when it is not.
    var debugRank: String? {
        guard heroHeader.debugStatFrames.first.flatMap({ $0 }) != nil else { return nil }
        return headerContent.counterValues.first ?? nil
    }
    /// Which Activity row a dismissal from the MAP is currently aimed at. The
    /// rule it pins is a product one — always the head of the list, holding the
    /// post the viewer was on — and its violation is a page that lands
    /// scrolled to an arbitrary row, which looks like a scroll position rather
    /// than like a bug.
    var debugLandingAnchor: PostID { anchorID }
    /// Where the list rests, from its top (#1610).
    var debugActivityOffset: CGFloat { activityPage.verticalOffset }
    var debugLikes: Int64 { likesTotal }
    /// How many hydrations reached the page — a refresh that brought the same
    /// members must leave it where it was.
    var debugRenderCount: Int { renders }
    /// Releases a pull on the page, as a finger letting go does.
    func debugReleasePull(by distance: CGFloat = HeroPullToRefreshView.threshold + 40) {
        loadViewIfNeeded()
        activityPage.debugReleasePull(by: distance)
    }
    /// Whether the page leads with the Popular row and titles its list
    /// Recent.
    var debugSectionTitles: (row: String, list: String) { (shelf.title, lead.listTitle) }
    /// The Popular shelf (#1296), for tests.
    var debugShelf: PostShelfSection { shelf }
    /// Taps Popular card `index` through the row's own handler.
    func debugOpenPopularCard(at index: Int) -> Bool {
        guard shelf.cards.indices.contains(index) else { return false }
        openCard(at: index)
        return true
    }
    /// Taps Recent item `index` through the page's selection path, the one
    /// a finger reaches. False while it is not loaded yet.
    func debugOpenTile(at index: Int) -> Bool {
        activityPage.debugSelectItem(at: index)
    }
    /// Taps a section title, as a finger does.
    func debugTapPopularTitle() { pushPopularList() }
    func debugTapRecentTitle() { pushGallery() }
    /// Whether the pull's spinner is still turning.
    var debugIsRefreshing: Bool { pullIndicator.debugIsRefreshing }
    /// Whether any page still carries a stock `UIRefreshControl`.
    var debugPagesCarryRefreshControl: Bool { activityPage.debugHasRefreshControl }
    var debugIsLoading: Bool { isLoading }
    var debugHeroName: String? { headerContent.title }
    /// Drives the active page to a travel offset through the same path a
    /// finger's scroll reports through.
    func debugScrollActivePage(to offset: CGFloat) {
        activityPage.setVerticalOffset(offset)
        applyHeaderOffsetNow(activityPage.verticalOffset)
    }
}
#endif

// MARK: - The hero page's tabs

/// A place page's tabs: one page today, its posts — Popular over Recent. The
/// container supports more, with a selector at the foot (#1656); no place has
/// any yet.
enum PlaceProfileTab: Equatable {
    case posts
}

// MARK: - The map return flight's destination half
//
// This screen is BOTH sides of a zoom, deliberately: a SOURCE that refuses
// every flight (the map's registered intermediate, after `cardCloseGeometry`),
// and the DESTINATION of its own dismissal to the map — the whole page lifts
// off and the marker's card (built by `MapPinZoomSource`, the marker's exact
// twin) flies home to the cluster. The two conformances share one member,
// `zoomAdoptLiveMediaView`, a no-op declared beside the source's floor.
extension PlaceProfileViewController: ZoomTransitionDestination {
    /// ⚠️ FALSE, and this is the member that exists BECAUSE of this screen.
    ///
    /// Conforming to this protocol used to be read across the shell as "a
    /// full-bleed surface that covers the dock" — a question it never asked.
    /// This page flies home to a map marker like a snap surface AND shows the
    /// app's tab bar like the ordinary navigation citizen it is, which is
    /// what made the two come apart: the day it gained this conformance, the
    /// shell started hiding the dock underneath it and the restores that run
    /// on the way back stopped firing.
    var concealsAppTabBar: Bool { false }

    /// The card lifts from the whole page.
    func zoomTargetFrame(in container: UICoordinateSpace) -> CGRect {
        view.convert(view.bounds, to: container)
    }

    /// The flying card is the MARKER's face — the source builds it; this
    /// page has no per-post chrome to ride along.
    func zoomFlightChrome() -> UIView? { nil }

    func setZoomContentHidden(_ hidden: Bool) {
        view.isHidden = hidden
    }

    func zoomTransitionDidEnd() {}

    var isReadyForInteractiveDismissal: Bool { true }

    /// TRUE ONLY WHILE THE HERO RETURN IS INSTALLED. The default (`true`,
    /// "this screen owns its dismissal") tells `NativePopPolicy` to refuse
    /// the native edge pop — correct when the grab below is armed, and
    /// exactly wrong for the fallback case where `mapReturn` yielded nothing
    /// and the native slide IS the dismissal.
    var zoomOwnsInteractiveDismissal: Bool { mapReturnTransition != nil || markerCloseDriver != nil }

    /// A WINDOW when the map handed one over (`markerClose`): the kind the
    /// slide driver closes itself instead of forwarding to a hero.
    var zoomDismissalKind: ZoomDismissalKind { markerClose != nil ? .card : .hero }

    /// A rightward drag means "previous tab" everywhere but the first one —
    /// the profile pager's own rule. The back button flies from any tab. And
    /// on a card's carousel with a photograph to its left, the carousel is
    /// the tenant and wins its own territory.
    func zoomHorizontalDismissalPermitted(at location: CGPoint, in view: UIView) -> Bool {
        let point = self.view.convert(location, from: view)
        let isPushed = navigationController.map { $0.viewControllers.first !== self } ?? false
        // ⚠️ THE EDGE IS NOT THE FIRST TAB'S PRIVILEGE. This asked only "am I on
        // the first tab" and refused everything else outright — including the
        // leading strip, which `HorizontalPagerScrollView` had already yielded
        // as the platform's own. Two surfaces both giving the drag up leaves it
        // claimed by nobody: on the Activity tab a rightward swipe did nothing
        // at all, from anywhere. Reported.
        guard PagedScreenDismissalPolicy.allowsDismissal(
            atX: point.x, activeIndex: activeIndex, isPushed: isPushed
        ) else { return false }
        // On the strip the answer is already yes — it is absolute, the way the
        // pager treats it. Elsewhere the drag may still belong to a carousel
        // under the finger.
        //
        // ⚠️ `-1`: the drag is RIGHTWARD and pages run the other way to the
        // finger. Both rules ask the same question — what else could this
        // drag be for — see `MediaCarouselTouchRouting`.
        guard point.x > PagedScreenDismissalPolicy.edgeZone else { return true }
        return MediaCarouselTouchRouting.dragPassesThroughCarousel(
            at: point, in: self.view, towardsPageDelta: -1
        )
    }

    /// Freeze the tab pager while a grab drives, so the drag that is flying
    /// the page home cannot also page it sideways.
    ///
    /// RESTORED, not re-enabled: paging can be off for its own reasons (a
    /// multi-selection in progress), and a grab ending must hand back the
    /// state it found — the feed's `ScrollLock` rule.
    ///
    /// ⚠️ ONE DRAG, ONE OWNER (#1595, the owner 2026-10-22): there is no
    /// pager, but there ARE horizontal scrollers under the finger — every
    /// post's media carousel and the Popular shelf. A grab that began left
    /// them live, so a drag the close had taken also paged a carousel, both
    /// following the finger. The vertical feed freezes its carousels for
    /// exactly this (`SnapFeedViewController.setContentScrollEnabled`); the
    /// place page now does too.
    ///
    /// ⚠️ AND THE PAGE'S OWN LIST (the owner, on device, 2026-10-23): the
    /// list was left live, and a grab whose finger drifted up or down
    /// scrolled the page INSIDE the window that was flying it home. The
    /// window holds a still page; every scroller under it freezes.
    func setContentScrollEnabled(_ enabled: Bool) {
        if enabled {
            for entry in grabFrozenScrollers {
                guard let scroller = entry.scroller else { continue }
                if let carousel = scroller.superview as? MediaCarouselView {
                    carousel.setScrollEnabled(entry.wasEnabled)
                } else {
                    scroller.isScrollEnabled = entry.wasEnabled
                }
            }
            grabFrozenScrollers = []
            return
        }
        // Re-entrant: a grab that reports its start twice must not record
        // `false` as the state to restore.
        guard grabFrozenScrollers.isEmpty else { return }
        for scroller in Self.grabFrozenScrollers(in: view) {
            grabFrozenScrollers.append(GrabFrozenScroller(scroller: scroller, wasEnabled: scroller.isScrollEnabled))
            if let carousel = scroller.superview as? MediaCarouselView {
                // Stops a glide too, so no page changes under the close.
                carousel.setScrollEnabled(false)
            } else {
                scroller.setContentOffset(scroller.contentOffset, animated: false)
                scroller.isScrollEnabled = false
            }
        }
    }

    /// Every scroll view under `root` — the page's list, the shelf, the
    /// posts' carousels — that a grab freezes.
    static func grabFrozenScrollers(in root: UIView) -> [UIScrollView] {
        var found: [UIScrollView] = []
        var stack: [UIView] = [root]
        while let view = stack.popLast() {
            if let scroller = view as? UIScrollView, scroller !== root {
                found.append(scroller)
            }
            stack.append(contentsOf: view.subviews)
        }
        return found
    }
}

/// A scroller a place-page grab froze, and what to put back (#1595).
private struct GrabFrozenScroller {
    weak var scroller: UIScrollView?
    let wasEnabled: Bool
}
