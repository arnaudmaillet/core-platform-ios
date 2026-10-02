import CoreModels
import CoreNavigation
import CoreStorage
import DesignSystem
import FeedInterface
import MediaCore
import MediaPlayback
import PostGrid
import UIKit

/// The PLACE PROFILE that sits BENEATH a semantic-cluster feed (Case B of the
/// cluster-gallery milestone, redesigned to read like a profile page):
/// tapping a City/Country/Region cluster on the map lands on the snap feed
/// with this screen already on the stack under it, and a downward grab on the
/// feed closes the active post onto the FIRST ROW of its Activity tab here —
/// whatever kind of post the marker wore and whatever post is on screen.
///
/// The page is a profile-shaped column:
/// - a HERO BANNER wearing the place's TOP post (highest engagement — the
///   same ranking the Gallery leads with, so banner, pin face and first tile
///   are one post);
/// - a metric band: the place's rank, when it has one, and its aggregated
///   LIKES — likes, not views, since no surface shows views any more (product
///   call, 2026-09-30). No avatar, no bio, no edit/share — a place is not an
///   account;
/// - two tabs under the metrics — **Discover** (the popularity grid) and
///   **Activity** (every post as CARDS, most popular first) — Activity on the
///   left, Discover on the right (`tabOrder`) — a `PagedTabBar`
///   over a `HorizontalPagerView`, the same pairing the profile's
///   relationship screen ships. Deliberately For You's own vocabulary and
///   shapes: its Discover is a media grid and its Following is a card list,
///   which is exactly this pair for one place.
/// The follow-this-place pin and a "..." menu keep the top-right slots.
///
/// It remains an ordinary navigation citizen — plain title ("Paris • City
/// Cluster"), tab bar visible, native edge-pop back to the map — because
/// every special behaviour of the flow lives in the TRANSITIONS, not in the
/// screen: the two-VC stack insertion is the map's, the vertical close is
/// the card close's, and this type only has to host its column and say where
/// that close lands (`CardCloseLanding`).
final class PlaceProfileViewController: UIViewController {
    /// The Discover tab's grid of covers.
    private let page: ForYouGridPage
    /// The Activity tab: the SAME component For You's "Following" is — a
    /// `ForYouGridPage` in `.list` style — over the same corpus in popularity
    /// order, and the landing of every dismissal from the map. Not a bespoke
    /// list: a place's activity is posts,
    /// and a viewer who reads them as cards on For You must read them as the
    /// same cards here.
    private let activityPage: ForYouGridPage

    /// The banner's viewport. The PICTURE inside it is cut taller than it is,
    /// so it can lag behind the scroll without ever showing an edge — see
    /// `applyBannerParallax`.
    private let bannerBox = UIView()
    /// The picture, its foot progressively blurred under the name — the
    /// profile banner's run-out, shared through `HeroBannerFade`.
    private let bannerView = HeroBannerPictureView()
    /// The page's tone over the picture's last few points, under the
    /// counters and the selector.
    private let bannerRamp = HeroBannerRampView()
    /// "#3 City Rank" — the first counter, when the place has a rank to show.
    private let rankMetric = PlaceMetricView(title: "Rank")
    /// The heart every tile of this page counts, summed. It used to sit beside
    /// a "Views" total and be called "Reactions"; the views went (2026-09-30)
    /// and the word became the tiles' own.
    private let likesMetric = PlaceMetricView(title: "Likes")

    /// The page's two tabs, by what they ARE rather than where they sit.
    enum Tab: Equatable {
        case activity, discover

        var title: String {
            switch self {
            case .activity: "Activity"
            case .discover: "Discover"
            }
        }
    }

    /// Strip order == pager order == `hostedPages` order: Activity on the
    /// LEFT, Discover on the right (product call, 2026-09-28 — the same swap
    /// For You's Following/Discover got).
    ///
    /// ⚠️ EVERY POSITION IS ASKED OF THIS ARRAY (`index(of:)`), never written
    /// as a literal. The staging of a landing, the header's alignment, the
    /// autoplay gate and the tab strip all speak in indices; the order used to
    /// live in five `0`s and `1`s, and a swap that missed one would land a
    /// close on the right tab's INDEX with the wrong tab's page.
    static let tabOrder: [Tab] = [.activity, .discover]

    /// Where `tab` sits in the strip and the pager.
    static func index(of tab: Tab) -> Int {
        tabOrder.firstIndex(of: tab) ?? 0
    }

    /// The tab titles, one source for both selector copies.
    private static let tabTitles = tabOrder.map(\.title)
    /// ⚠️ **ONE STRIP NOW, AND THE HAND-OVER IS GONE WITH THE SECOND.** There
    /// were two — an inline copy in the header's slot and a docked copy in the
    /// navigation bar's leading group — crossfading at a threshold as the
    /// header scrolled away, because a re-parented view cannot be in two places
    /// during a transition. The strip lives at the foot of the screen now and
    /// never leaves it, so there is nothing to hand over: no slot, no dock
    /// line, no speed limit, no mirroring latch.
    private let tabBar = PagedTabBar(titles: tabTitles, style: .navigationTitle)
    /// The strip's home: a `UITabAccessory` at the foot of the screen.
    ///
    /// ⚠️ AN ACCESSORY AND NOT A TOOLBAR, EVEN THOUGH THIS SCREEN IS PUSHED.
    /// It is pushed with the app's tab bar STILL ON SCREEN — it never sets
    /// `hidesBottomBarWhenPushed` and re-asserts the bar itself — so the band
    /// above that bar is the accessory's. The toolbar of this stack belongs to
    /// the snap feed, whose exit leg reads the incoming screen's
    /// `toolbarItems`: giving this page any would flip that from "hide the bar"
    /// to "hand it over".
    private var selectorAccessory: SelectorAccessory?
    private var pager: HorizontalPagerView!

    /// The floating header: banner + metrics + tab bar in one host that
    /// RIDES THE ACTIVE PAGE'S OFFSET (the profile page's mechanics, adopted
    /// wholesale). The pages fill the screen and scroll themselves; this
    /// host sits above them, moved by its top constraint, and stops moving
    /// when the tab bar reaches the navigation bar — the sticky dock.
    private let headerHost = UIView()
    private var headerTopConstraint: NSLayoutConstraint?
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
    private let rank: PlaceRankBadge?
    /// The banner's hero identity: the place's name, and nothing else.
    ///
    /// ⚠️ THE KIND LINE WAS DELETED, not hidden. "CITY CLUSTER" whispered above
    /// the name was a taxonomy label competing with the identity — and the map
    /// the viewer just came from had already said which kind of cluster this
    /// is. The SPLITTER stays: `placeName` still arrives as the gallery's
    /// "Paris • City Cluster", so stripping the kind is the only way to draw
    /// the name alone.
    private let heroNameLabel = UILabel()
    /// The two pages under their hosted-header contract, pager order.
    private var hostedPages: [any PlaceProfileHostedPage] = []
    /// Which page the header is riding. Adopted at tab-tap time (the
    /// destination takes the offset BEFORE it travels) and confirmed on
    /// swipe settle.
    ///
    /// Starts on the FIRST tab, which is Activity: every arrival from the map
    /// lands there anyway (`stageActivityLanding`), so the page's resting tab
    /// and its landing tab are one tab — a close that fell back to the plain
    /// slide shows the same tab the window would have.
    private var activeIndex = 0

    private let postIDs: [PostID]
    private let imagePipeline: ImagePipeline
    private let loadPosts: () async throws -> [GalleryPost]
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
    /// The two trailing items, held so the bar's group is composed in one
    /// place — see `configureNavigationItems`. Either can be nil: the pin
    /// needs a follow seam, the balance needs a wallet.
    private var followItem: UIBarButtonItem?
    private var walletItem: UIBarButtonItem?
    /// The viewer's spendable balance, in the same face it wears on the map,
    /// For You, the profile and the post screen.
    private let walletBadge = WalletBadgeButton()
    private let wallet: WalletStore?
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
    /// The pull's spinner, pinned under the status bar — the profile's.
    private let pullIndicator = HeroPullToRefreshView()
    /// The band the spinner centres in — the profile's height.
    private static let pullIndicatorHeight: CGFloat = 44
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

    /// The tile a flight left THIS page from, and which tab it sat on — nil
    /// whenever the open post did not come from here (the map's Case B, where
    /// the viewer arrived from a marker and has never seen this grid).
    ///
    /// It is the whole of what distinguishes the two card-shaped closes: one
    /// has somewhere the viewer actually was, the other does not.
    private var tileDeparture: (id: PostID, isActivity: Bool)?


    /// The page's own hero return to the map — created once, then installed
    /// as the stack's delegate whenever this page is top, so BOTH the back
    /// button and the horizontal grab fly home to the marker instead of
    /// sliding. Retained here (the controller holds its destination weakly).
    private var mapReturnTransition: ZoomTransitionController?
    /// Whoever owned the delegate slot before this page's first install —
    /// handed the slot back when the page pops for good.
    private weak var mapReturnPreviousDelegate: (any UINavigationControllerDelegate)?

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // The BACKSTOP, on UIKit's own animation like every other install
        // (native chrome is UIKit's — see `TabBarRevealPolicy`). A tab switch
        // and a committed close install from `viewWillAppear` and find nothing
        // to do here.
        selectorAccessory?.install(into: tabBarController, minimizesOnScroll: true,
                                   alongside: transitionCoordinator)
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
        // The flight that left here is over, whichever way it ended. A stale
        // departure would answer for the NEXT close — including the map's Case
        // B, whose whole point is that it has no departure on this page.
        tileDeparture = nil
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
        if let markerClose {
            installMarkerClose(markerClose, on: nav)
            return
        }
        if mapReturnTransition == nil,
           let source = mapReturn?({ [weak self] in self?.departureStill() }) {
            let transition = ZoomTransitionController(source: source, destination: self)
            transition.attachInteractiveDismissal(to: view, axes: [.horizontal]) { [weak nav] in
                nav?.popViewController(animated: true)
            }
            transition.onSourceReturned = { [weak self, weak nav] in
                // Landed on the map: the flow is over, the slot goes back to
                // whoever owned it before this page existed.
                guard let self, let nav else { return }
                if nav.delegate === self.mapReturnTransition {
                    nav.delegate = self.mapReturnPreviousDelegate
                }
            }
            mapReturnTransition = transition
        }
        guard let transition = mapReturnTransition, nav.delegate !== transition else { return }
        if mapReturnPreviousDelegate == nil {
            mapReturnPreviousDelegate = nav.delegate
        }
        // ⚠️ AND THE DISPLACED DELEGATE IS TOLD, not merely remembered. This
        // page becomes top DURING the pop that lands on it, so it takes the
        // slot before UIKit delivers `didShow` — and the driver that flew the
        // feed here never learns its dismissal landed. Its owner's
        // `onDismissedToIntermediate` is that news, and without it the map
        // keeps its re-entrancy lock, its concealed marker and its whole
        // transition graph alive for the rest of the session.
        transition.displacedDelegate = mapReturnPreviousDelegate
        nav.delegate = transition
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
        }
        markerCloseDriver?.install(on: nav)
    }

    #if DEBUG
    private var didScheduleDebugPop = false
    private var didScheduleDebugDrives = false

    /// `-maps-place-pop-demo`: pops this page ~1.5s after it becomes top —
    /// the sim can't tap the back button, and the non-interactive pop is
    /// exactly the leg that proves the hero return animator is installed.
    /// `-maps-place-tab <activity|discover|index>` selects a tab (a NAME
    /// survives a reorder of the strip; an index is its position, left to
    /// right) and `-maps-place-scroll <pt>`
    /// drives the active page's offset — the two gestures this screen is
    /// read by, neither of which the simulator can inject. The scroll runs
    /// last and later, so a run can ask for "the Activity tab, docked".
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
                self?.bannerView.image != nil
            }) { [weak self] in
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                    guard let self, let measured = debugHeroInkContrast() else { return }
                    let style = traitCollection.userInterfaceStyle == .dark ? "dark" : "light"
                    let rows = measured.map { "\($0.0)=[\($0.1)]" }.joined(separator: " ")
                    print("PLACE-INK-AUDIT style=\(style) tones=\(debugHeroInkTones) \(rows) "
                        + String(format: "blur-bake=%.1fms", debugBlurBakeMilliseconds))
                }
            }
        }
        if let position = arguments.firstIndex(of: "-maps-place-tab"),
           position + 1 < arguments.count,
           let index = Self.debugTabIndex(arguments[position + 1]) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
                self?.tabBar.debugSimulateTap(at: index)
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
                    guard let self, self.hostedPages.indices.contains(self.activeIndex),
                          let grid = self.hostedPages[self.activeIndex] as? ForYouGridPage
                    else { return false }
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
                    guard let self, self.hostedPages.indices.contains(self.activeIndex),
                          let grid = self.hostedPages[self.activeIndex] as? ForYouGridPage
                    else { return false }
                    return !grid.posts.isEmpty && self.bannerView.image != nil
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
                    guard let self, self.hostedPages.indices.contains(self.activeIndex),
                          let grid = self.hostedPages[self.activeIndex] as? ForYouGridPage
                    else { return false }
                    return !grid.posts.isEmpty && self.bannerView.image != nil
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
                    debugReleasePull(on: Self.tabOrder[activeIndex])
                    print("[place] pull released on \(Self.tabOrder[activeIndex].title)"
                        + " refreshing=\(debugIsRefreshing)")
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
                    guard let self, self.hostedPages.indices.contains(self.activeIndex),
                          let grid = self.hostedPages[self.activeIndex] as? ForYouGridPage
                    else { return false }
                    return grid.posts.indices.contains(index)
                }) { [weak self] in
                    guard let self else { return }
                    debugFlightBeforeTileOpen = ZoomTransitionController.debugMostRecent
                    debugDidOpenTile = true
                    let grid = hostedPages.indices.contains(activeIndex)
                        ? hostedPages[activeIndex] as? ForYouGridPage : nil
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

    /// One frame of `-place-scroll-sweep`: 0 → 240pt → 0, eased, 3s a leg.
    private func debugSweepStep(began: CFTimeInterval, probe: HeroScrollFrameProbe) {
        let t = CACurrentMediaTime() - began
        guard t < 6 else { return probe.finish() }
        let leg = t < 3 ? t / 3 : (6 - t) / 3
        probe.frame { debugScrollActivePage(to: CGFloat(240 * leg * leg * (3 - 2 * leg))) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0 / 60) { [weak self] in
            self?.debugSweepStep(began: began, probe: probe)
        }
    }

    /// One frame of `-place-stretch-sweep` (`HeroStretchSweep`).
    private func debugStretchStep(
        began: CFTimeInterval, probe: HeroScrollFrameProbe, phase: HeroStretchSweep.Phase?
    ) {
        guard let (now, offset) = HeroStretchSweep.at(CACurrentMediaTime() - began) else { return probe.finish() }
        if now != phase { probe.beginPhase(now.rawValue) }
        probe.frame { debugScrollActivePage(to: offset) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0 / 60) { [weak self] in
            self?.debugStretchStep(began: began, probe: probe, phase: now)
        }
    }

    /// The latest flight controller at the moment `-maps-place-open-tile`
    /// fired — WEAK, so remembering it keeps nothing alive; a controller that
    /// has since gone reads as nil, which is still "not the tile's".
    private weak var debugFlightBeforeTileOpen: ZoomTransitionController?
    private var debugDidOpenTile = false

    private func scheduleDebugPopIfRequested() {
        guard !didScheduleDebugPop,
              ProcessInfo.processInfo.arguments.contains("-maps-place-pop-demo")
        else { return }
        didScheduleDebugPop = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self, let nav = self.navigationController,
                  nav.topViewController === self else { return }
            nav.popViewController(animated: true)
        }
    }
    #endif
    private var bannerTask: Task<Void, Never>?
    /// The cover the banner wears.
    private var bannerURL: URL?

    /// How many posts seed a feed opened from a tile — the same window (and
    /// the same reason) as For You's.
    private static let seedWindow = 40
    /// The floor a headless or not-yet-laid-out view falls back to, so a
    /// constraint built before the first layout pass is never zero.
    private static let bannerHeightFloor: CGFloat = 220
    /// How far the image lags the scroll, as a fraction of the header's travel.
    /// Enough to read as depth, little enough that the crop stays honest.
    private static let bannerParallaxFraction: CGFloat = 0.25
    /// The gap between the name and the counters under it.
    private static let nameToMetricsGap: CGFloat = Spacing.lg

    /// The banner's height: the PROFILE POSTER's geometry, not a share of the
    /// screen.
    ///
    /// ⚠️ **IT WAS 70% OF THE VIEWPORT** — 612pt on an 874pt screen, the
    /// picture reaching two-thirds down before the name — beside a profile
    /// whose poster gives its picture a 200pt stage under the chrome. Two
    /// screens of one design, read as two products ("la bannière est beaucoup
    /// trop haute", 25 September 2026). Now it is the profile's rule: the
    /// chrome, `HeroBannerMetrics.posterStage` of picture, then the identity —
    /// the name and the counters — and the clearance under them. Re-derived on
    /// every layout, since the name and the counters grow with Dynamic Type.
    private var bannerHeight: CGFloat {
        let width = view.bounds.width - 2 * HeroBannerMetrics.identityInset
        guard width > 0 else { return Self.bannerHeightFloor }
        func height(of subject: UIView?) -> CGFloat {
            subject?.systemLayoutSizeFitting(
                CGSize(width: width, height: UIView.layoutFittingCompressedSize.height),
                withHorizontalFittingPriority: .required,
                verticalFittingPriority: .fittingSizeLevel
            ).height ?? 0
        }
        return view.safeAreaInsets.top + HeroBannerMetrics.posterStage
            + height(of: heroNameLabel) + Self.nameToMetricsGap + height(of: metricsBand)
            + Self.identityClearance
    }

    /// How much taller than its viewport the image is cut. The parallax slides
    /// the image by at most this, so the overshoot is what guarantees no edge
    /// is ever exposed.
    private var bannerOvershoot: CGFloat {
        max(1, headerTravel * Self.bannerParallaxFraction)
    }

    private var bannerHeightConstraint: NSLayoutConstraint?

    init(
        postIDs: [PostID],
        placeName: String = "",
        rank: PlaceRankBadge? = nil,
        imagePipeline: ImagePipeline,
        videoPlayback: VideoPlaybackController?,
        following: ClusterGalleryFollowing? = nil,
        wallet: WalletStore? = nil,
        makeWalletSheet: (@MainActor () -> UIViewController)? = nil,
        loadPosts: @escaping () async throws -> [GalleryPost],
        openPost: @escaping (UIViewController, SnapFeedHeroOrigin, [PostID]) -> Void
    ) {
        self.postIDs = postIDs
        self.placeName = placeName
        self.rank = rank
        self.imagePipeline = imagePipeline
        self.following = following
        self.wallet = wallet
        self.makeWalletSheet = makeWalletSheet
        self.loadPosts = loadPosts
        self.openPost = openPost
        self.anchorID = postIDs.first ?? PostID("")
        self.page = ForYouGridPage(
            imagePipeline: imagePipeline, style: .grid, videoPlayback: videoPlayback
        )
        self.activityPage = ForYouGridPage(
            imagePipeline: imagePipeline, style: .list, videoPlayback: videoPlayback
        )
        super.init(nibName: nil, bundle: nil)
        // The Activity list draws the same cards For You does, and its like
        // chips stake the same way.
        activityPage.staking = wallet.map(PostCardStaking.init)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    deinit {
        loadTask?.cancel()
        bannerTask?.cancel()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        // The page the cards lie on, a step below them — see `Surface`.
        view.backgroundColor = Surface.page
        configureHeader()
        configureTabs()
        page.render(.loading)
        activityPage.render(.loading)
        // Either page's "Try Again" reloads the whole place: one hydration
        // feeds both (`render`). The pull is the indicator's — `configureTabs`.
        page.onRefresh = { [weak self] in self?.refresh() }
        activityPage.onRefresh = { [weak self] in self?.refresh() }
        page.handPullToHost()
        activityPage.handPullToHost()
        installPullIndicator()
        page.onItemTapped = { [weak self] index in self?.openTile(at: index, in: self?.page) }
        activityPage.onItemTapped = { [weak self] index in
            self?.openTile(at: index, in: self?.activityPage)
        }
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
        page.onItemCommentsTapped = { [weak self] index in
            self?.openTile(at: index, in: self?.page, showingComments: true)
        }
        // The card band's own "..." stays dark here: the reporting and
        // social-graph seams are not threaded into this screen, and a menu
        // whose rows cannot act is worse than no control. An empty answer is
        // how `PostAuthorBandView` is told to hide it.
        activityPage.authorMenuActions = { _ in [] }
        configureNavigationItems()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        // ⚠️ **AS EARLY AS THE TRANSITION ALLOWS, AND `viewDidAppear` IS NOT
        // EARLY.** Measured on a tab switch, headless: `viewWillAppear` at
        // +36ms, `viewDidAppear` at +947ms — nine hundred milliseconds of empty
        // band under a screen already fully on display. The call below is
        // idempotent with the one in `viewDidAppear`, which stays as the
        // backstop for the paths the policy declines (a scrub that has not
        // committed, a flight that owns the chrome).
        installBottomChromeWhenAppearing(hasActiveFlight: false,
                                         handsOver: tabBarController?.bottomAccessory != nil) { [weak self] in
            guard let self else { return }
            selectorAccessory?.install(into: tabBarController, minimizesOnScroll: true,
                                       alongside: transitionCoordinator)
        }

        syncAutoplay()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        // ⚠️ ABOVE ANY OTHER GUARD. The accessory belongs to the tab bar
        // controller, not to this screen: a band left up floats over the feed
        // pushed on top of this page and over whichever tab comes next.
        selectorAccessory?.remove(from: tabBarController, alongside: transitionCoordinator)
        // Off screen, this page holds no claim on the shared player pool —
        // the feed pushed above it is about to want every loan.
        for hosted in hostedPages { (hosted as? ForYouGridPage)?.setAutoplayActive(false) }
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
            guard let page = hosted as? ForYouGridPage else { continue }
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

    /// How much of this screen's foot the tab bar actually covers — measured,
    /// because it floats over the pages rather than insetting them. Same
    /// quantity `landingOcclusion` takes for its bottom, asked of the bar.
    private var floatingBarCover: CGFloat {
        guard let bar = tabBarController?.tabBar, !bar.isHidden, let host = bar.superview
        else { return view.safeAreaInsets.bottom }
        let inPage = view.convert(bar.frame, from: host)
        return max(view.safeAreaInsets.bottom, view.bounds.maxY - inPage.minY)
    }

    /// Exactly one page may drive playback: two grids competing for one pool
    /// is how a working set of six turns into a queue nobody wins. For You's
    /// pager makes the same call from the same three places (settle, tab tap,
    /// appearance).
    private func syncAutoplay() {
        for (index, hosted) in hostedPages.enumerated() {
            (hosted as? ForYouGridPage)?.setAutoplayActive(index == activeIndex)
        }
    }

    // MARK: - Layout (floating header over full-screen pages)

    private func configureHeader() {
        // The PAGES fill the screen and scroll themselves; the header floats
        // over them (added second, so it draws above the content sliding
        // under it) and is moved by its top constraint from whichever page
        // is being read.
        let pages: [ForYouGridPage] = Self.tabOrder.map { tab in
            switch tab {
            case .activity: activityPage
            case .discover: page
            }
        }
        hostedPages = pages
        pager = HorizontalPagerView(pages: pages)
        pager.pin(to: view)

        headerHost.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(headerHost)
        let top = headerHost.topAnchor.constraint(equalTo: view.topAnchor)
        headerTopConstraint = top

        bannerBox.clipsToBounds = true
        bannerBox.backgroundColor = Surface.card
        bannerBox.translatesAutoresizingMaskIntoConstraints = false
        headerHost.addSubview(bannerBox)

        // Both fill the box; the picture slides INSIDE its view for the
        // parallax (`applyBannerParallax`), under a blur and a ramp that stay
        // with the type.
        bannerView.pin(to: bannerBox)
        bannerRamp.pin(to: bannerBox)
        // The blurred picture decides the type's ink — read it again the
        // moment it changes, off the bake's own dissolve when on screen.
        bannerView.onLevelsChanged = { [weak self] in
            guard let self else { return }
            guard view.isInVisibleWindow else { return updateHeroInk(force: true) }
            DispatchQueue.main.async { [weak self] in self?.updateHeroInk(force: true) }
        }

        // THE HERO TITLE: the place's name at the banner's foot, standing on
        // the picture — the identity leads the page, not the chrome.
        //
        // ⚠️ THE PICTURE'S INK, THE PROFILE'S RULE (`HeroInk`). It was
        // `.label` over a page-toned plate, which was only ~0.2–0.4 under the
        // name: black type over a dark photograph (or white over a bright
        // one, in dark mode) read faint. #327 put a black scrim under white
        // type; that read as a black veil and went (30 September 2026). What
        // stands under the name now is the picture's progressively blurred
        // foot (`HeroBannerFade`), and the name wears white or black by what
        // that blurred picture is behind it (`updateHeroInk`) — white alone
        // measured 2.34:1 over this page's light mock picture.
        heroNameLabel.text = Self.heroTitleComponents(of: placeName).name
        // ⚠️ 34 LITERAL, not read back from `preferredFont(forTextStyle:).pointSize`.
        //
        // That value ALREADY reflects the current content-size category, so
        // feeding it to `UIFontMetrics.scaledFont` scales it a second time —
        // the frozen `.title1.pointSize` this replaces had the same shape of
        // bug in reverse: it sampled the category once, at construction, and
        // never grew again. 34 is `largeTitle` at `.large`, which is exactly
        // the base `scaledFont` expects to be handed.
        //
        // Up from 28: the banner grew by 17% and 28 was sized for the old one,
        // so holding it would have made the identity proportionally SMALLER
        // inside a larger picture.
        heroNameLabel.font = UIFontMetrics(forTextStyle: .largeTitle).scaledFont(
            for: .systemFont(ofSize: 34, weight: .bold), maximumPointSize: 40
        )
        heroNameLabel.adjustsFontForContentSizeCategory = true
        heroNameLabel.accessibilityTraits = .header
        heroNameLabel.adjustsFontSizeToFitWidth = true
        heroNameLabel.minimumScaleFactor = 0.6
        // ⚠️ LEADING, on the profile's column: the place's name stands where
        // an account's does on a poster, so the two pages read as one design.
        heroNameLabel.textAlignment = .natural
        applyHeroLegibility()
        heroNameLabel.translatesAutoresizingMaskIntoConstraints = false
        bannerBox.addSubview(heroNameLabel)

        // The profile's counter row: equal cells across the full column width,
        // the place's rank first when it has one (a hidden cell takes no
        // share of the row).
        rankMetric.isHidden = rank == nil
        if let rank {
            rankMetric.setText(rank.positionText, title: rank.label)
        }
        let metrics = UIStackView(arrangedSubviews: [rankMetric, likesMetric])
        metrics.distribution = .fillEqually
        // No spacing: the cells ARE the spacing, equal across the column, as
        // on the profile. (The old +xxl answered a centred pair that clumped
        // in the middle of the screen; the row spans the column now.)
        metrics.spacing = 0
        metrics.alignment = .top
        metrics.translatesAutoresizingMaskIntoConstraints = false
        // ⚠️ INSIDE THE BANNER, under the name, ON THE PICTURE. The counters
        // are part of the place's identity, so they stand on its picture as a
        // poster's do on a profile — in the picture's ink, read off the
        // blurred picture behind them — and the page arrives only over the
        // banner's last few points, where the list begins (user, 30
        // September 2026; they were briefly on a page band under the name).
        //
        // Their bottom still keeps the old selector slot's clearance, derived
        // from the bar's own height rather than typed as a constant: the
        // header's height and every inset derived from it hang off it.
        bannerBox.addSubview(metrics)
        self.metricsBand = metrics


        // ⚠️ Stretchy banner, the profile's own mechanism: the host is moved
        // by its TOP CONSTRAINT rather than a transform precisely so this
        // works — the banner's top is pinned `lessThanOrEqualTo` the view's
        // top at required priority over its natural host-top equality, so a
        // pull-down (the host travelling below rest) stretches the banner
        // from the viewport's top edge instead of dragging it away and
        // exposing the background behind.
        let bannerRestingTop = bannerBox.topAnchor.constraint(equalTo: headerHost.topAnchor)
        bannerRestingTop.priority = .defaultHigh
        let bannerBottom = bannerBox.bottomAnchor.constraint(
            equalTo: headerHost.topAnchor, constant: bannerHeight
        )
        bannerHeightConstraint = bannerBottom
        NSLayoutConstraint.activate([
            top,
            headerHost.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            headerHost.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            bannerRestingTop,
            bannerBox.topAnchor.constraint(lessThanOrEqualTo: view.topAnchor),
            bannerBox.leadingAnchor.constraint(equalTo: headerHost.leadingAnchor),
            bannerBox.trailingAnchor.constraint(equalTo: headerHost.trailingAnchor),
            // The BOTTOM is the fixed edge (host.top + bannerHeight), so a
            // stretched banner grows upward while the title holds still.
            bannerBottom,
            // The hero title rides the banner's FIXED bottom edge (see the
            // stretch note above), so a pull-down stretches the image behind
            // it while the name holds its seat over the blur. Leading, with
            // the counters directly beneath it.
            heroNameLabel.leadingAnchor.constraint(
                equalTo: bannerBox.leadingAnchor, constant: HeroBannerMetrics.identityInset
            ),
            heroNameLabel.trailingAnchor.constraint(
                lessThanOrEqualTo: bannerBox.trailingAnchor, constant: -HeroBannerMetrics.identityInset
            ),
            metrics.topAnchor.constraint(
                equalTo: heroNameLabel.bottomAnchor, constant: Self.nameToMetricsGap
            ),
            metrics.leadingAnchor.constraint(
                equalTo: bannerBox.leadingAnchor, constant: HeroBannerMetrics.identityInset
            ),
            metrics.trailingAnchor.constraint(
                equalTo: bannerBox.trailingAnchor, constant: -HeroBannerMetrics.identityInset
            ),
            // ⚠️ DERIVED FROM THE BAR, not typed. The selector now stands
            // INSIDE the banner's own rectangle, so the identity's foot has to
            // clear a capsule rather than the picture's edge: the old -18 put
            // the counters straight behind the glass the moment the bar moved
            // up. Deriving it means a change to the bar's height cannot leave
            // type drawn underneath it.
            metrics.bottomAnchor.constraint(
                equalTo: bannerBox.bottomAnchor, constant: -Self.identityClearance
            ),
            // ⚠️ **THE BANNER'S BOTTOM IS WHAT GIVES THE HOST A HEIGHT NOW.**
            // It used to be the selector slot's, which was a sibling pinned to
            // `headerHost.bottomAnchor` — delete the slot without this and
            // `headerHeight` goes ambiguous, taking the pages' inset and every
            // number derived from it with it.
            bannerBox.bottomAnchor.constraint(equalTo: headerHost.bottomAnchor),
        ])
    }

    /// The inline selector's seat: the bar's own height plus the gap that
    /// separates it from the first row of content.
    private static let selectorSlotHeight = PagedTabBar.Style.navigationTitle.height + 16
    /// The air the slot keeps BELOW the selector, now that the bar itself sits
    /// on the banner's last 44pt. Derived, so the two cannot drift apart.
    private static let selectorSlotFooter =
        selectorSlotHeight - PagedTabBar.Style.navigationTitle.height
    /// How far the identity's foot must clear the banner's bottom edge: the
    /// selector's own band, plus real air. Derived from the bar for the reason
    /// the constraint states — type must never be drawn behind the capsule.
    private static let identityClearance =
        PagedTabBar.Style.navigationTitle.height + Spacing.xl
    /// The crossfade's length and the size the leaving copy shrinks to —
    /// the profile screen's measured pair, shared so the two screens that
    /// perform the same hand-over cannot drift apart.
    private static let dockTransition: TimeInterval = 0.26
    private static let dockZoomScale: CGFloat = 0.88

    private var metricsBand: UIStackView!

    private func configureTabs() {
        // The header rides the ACTIVE page's offset — every page reports,
        // the coordinator listens to one.
        for (index, hosted) in hostedPages.enumerated() {
            hosted.onVerticalScroll = { [weak self] offset in
                guard let self, index == activeIndex else { return }
                applyHeaderOffset(offset)
                // Negative travel is the overscroll the indicator draws from.
                pullIndicator.setPull(max(0, -offset))
            }
            // The profile's release rule, verbatim: the indicator owns the
            // threshold, and a release past it refreshes the whole place.
            hosted.onPullReleased = { [weak self] distance in
                guard let self, index == activeIndex,
                      pullIndicator.shouldRefresh(releasedAt: distance) else { return }
                pullIndicator.beginRefreshing()
                refresh()
            }
        }
        // Tap → the destination takes its aligned position BEFORE it
        // travels, and the header adopts it immediately — so the page
        // sliding in is already where it belongs.
        // BOTH copies answer a tap — whichever the finger reached — and both
        // are told the outcome, so the invisible one is already correct when
        // it fades in rather than catching up afterwards.
        for bar in [tabBar] {
            bar.addAction(UIAction { [weak self, weak bar] _ in
                guard let self, let bar else { return }
                let destination = bar.selectedIndex
                mirrorSelection(to: destination)
                guard destination != activeIndex, hostedPages.indices.contains(destination)
                else { return }
                hostedPages[destination].setVerticalOffset(alignedOffset(for: destination))
                activeIndex = destination
                syncAutoplay()
                pager.setActivePage(destination, animated: true)
                applyHeaderOffset(hostedPages[destination].verticalOffset)
            }, for: .valueChanged)
        }
        // Drag on the pill → pages. The neighbour alignment below rides it for
        // free, since a scrub moves the offset and `onProgress` answers.
        tabBar.onScrub = { [weak self] progress in self?.pager.scrub(to: progress) }
        tabBar.onScrubEnd = { [weak self] velocity in
            self?.pager.settleAfterScrub(velocityInPages: velocity)
        }
        // Swipe → lens, every frame — and the neighbours are settled every
        // frame too: mid-swipe both pages are on screen, and a neighbour
        // arriving at a stale offset is a header jump the viewer watches.
        pager.onProgress = { [weak self] progress in
            guard let self else { return }
            tabBar.setProgress(progress)
            for (index, hosted) in hostedPages.enumerated() where index != activeIndex {
                hosted.setVerticalOffset(alignedOffset(for: index))
            }
        }
        // The band's minimize rides whichever page is in front. The pager is
        // what knows, and it is what says so — see `onActiveScrollViewChanged`.
        pager.onActiveScrollViewChanged = { [weak self] scroller in
            self?.setContentScrollView(scroller, for: .bottom)
        }
        pager.onSettled = { [weak self] index in
            guard let self, hostedPages.indices.contains(index) else { return }
            activeIndex = index
            mirrorSelection(to: index)
            syncAutoplay()
            // Re-read where the landed page ACTUALLY is — a short page takes
            // as much of the shared offset as it has content for, and a
            // header riding a stale number stays hidden over a page sitting
            // at its top.
            applyHeaderOffset(hostedPages[index].verticalOffset)
        }
    }

    /// Puts the strip on a selection the pager reached by itself.
    ///
    /// ⚠️ THE RE-ENTRANCY LATCH IS GONE WITH THE SECOND COPY. It existed
    /// because `select` fires `.valueChanged`, whose action mirrored back into
    /// the other bar; with one strip the guard below is the whole of it.
    private func mirrorSelection(to index: Int) {
        guard tabBar.selectedIndex != index else { return }
        tabBar.select(index)
    }

    // MARK: - The scroll coordinator (the profile page's arithmetic)

    /// Which ink the name and each counter wear on the picture — read off
    /// the blurred picture behind each (`updateHeroInk`); see `HeroInk`.
    /// Per COUNTER, not per row: the two columns stand half a banner apart,
    /// and one ink for the row was the worse of two grounds (a light wall
    /// under one, dark hair under the other measured 2.3:1 in either ink).
    private var nameTone = HeroInk.defaultTone
    private var rankTone = HeroInk.defaultTone
    private var likesTone = HeroInk.defaultTone
    private var heroInkReadFor: [CGRect] = []
    #if DEBUG
    /// How many times the ground under the type was read.
    private(set) var debugInkReadCount = 0
    #endif

    /// The name's and the counters' ink and edge: the picture's ink (white on
    /// a dark picture, black on a light one) with a soft shadow of the
    /// opposite tone — it holds a glyph where the picture puts its own tone
    /// right behind it.
    private func applyHeroLegibility() {
        heroNameLabel.textColor = nameTone.primary
        HeroInk.applyShadow(to: heroNameLabel, tone: nameTone, onPicture: 1)
        rankMetric.setInk(tone: rankTone)
        likesMetric.setInk(tone: likesTone)
    }

    /// Reads the blurred picture behind the name and behind each counter and
    /// picks each one's ink. Runs when the picture is re-baked and when the
    /// type moves; a change of ink on screen cross-dissolves.
    private func updateHeroInk(force: Bool = false) {
        HeroBannerCost.measure(.ink) { readHeroInk(force: force) }
    }

    private func readHeroInk(force: Bool) {
        // In the box's space AT REST, what the ground is read in: the type
        // rides the box's foot, and in the box's own space a pull-down (the
        // box stretching up) moved it down its ground and read the ground
        // again every two points of the pull.
        let blocks = [heroNameLabel, rankMetric, likesMetric].map(restingFrame(of:))
        let moved = blocks.count != heroInkReadFor.count
            || zip(blocks, heroInkReadFor).contains { abs($0.minY - $1.minY) > 2 || abs($0.height - $1.height) > 2 }
        guard force || moved, let nameGround = bannerView.groundPixels(behind: blocks[0]) else { return }
        heroInkReadFor = blocks
        #if DEBUG
        debugInkReadCount += 1
        #endif
        let name = HeroInk.tone(forGround: nameGround, current: nameTone)
        var rank = rankTone
        if !rankMetric.isHidden, let ground = bannerView.groundPixels(behind: blocks[1]) {
            rank = HeroInk.tone(forGround: ground, current: rankTone)
        }
        var likes = likesTone
        if let ground = bannerView.groundPixels(behind: blocks[2]) {
            likes = HeroInk.tone(forGround: ground, current: likesTone)
        }
        #if DEBUG
        HeroInk.debugTraceGround(nameGround, name: "place-name", picked: name)
        #endif
        guard name != nameTone || rank != rankTone || likes != likesTone else { return }
        nameTone = name
        rankTone = rank
        likesTone = likes
        guard view.isInVisibleWindow else { return applyHeroLegibility() }
        UIView.transition(
            with: bannerBox, duration: 0.2, options: [.transitionCrossDissolve, .allowUserInteraction]
        ) {
            self.applyHeroLegibility()
        }
    }

    /// Hands the fade where the type landed: from just above the name — the
    /// identity's top, as a profile's avatar is its — down to the banner's
    /// foot, the blur barely there under the name and the page's tone
    /// already half there (shouldered), both whole where the list begins. The whole identity stands on the picture, as on a
    /// profile's poster. The box is settled first — the controller's pass
    /// runs before the box's own subviews are placed.
    ///
    /// ⚠️ It used to be a page-toned PLATE a third of the banner tall — a
    /// ladder climbing from the name's foot, with the counters' values on
    /// 0.55 of it and their captions on 0.93 — under #327's black ink scrim.
    /// Both went (30 September 2026): the plate's long climb was the white
    /// halo over the photograph, the scrim a black veil. `HeroBannerFade` is
    /// the profile banner's run-out too, so the two screens cannot drift.
    private func placeHeroFade() {
        guard let metricsBand else { return }
        bannerBox.layoutIfNeeded()
        // In the box's space AT REST: a pull-down stretches the box above,
        // and must not move the fade — see `HeroBannerPictureView`.
        let name = restingFrame(of: heroNameLabel)
        let foot = bannerBox.bounds.height - restingDrop
        guard name.height > 0, metricsBand.frame.height > 0, foot > name.minY else { return }
        // Shouldered, as a profile's poster: the name stands on the picture
        // where the blur is still nil, so the page's tone is already half
        // there under it.
        let fade = HeroBannerFade.shoulderedGeometry(identityTop: name.minY, foot: foot)
        bannerView.fade = fade
        bannerRamp.fade = fade
        updateHeroInk()
    }

    /// How far a pull-down has stretched the box above its resting top:
    /// what it is taller than its resting height (`bannerHeight`, its foot
    /// below the host's top, which is where its top rests).
    ///
    /// ⚠️ READ OFF THE BOX'S OWN BOUNDS, not its frame in the host: this
    /// runs in the controller's layout pass, before the host has placed the
    /// box, and the host-relative frame lagged the box's insides by a
    /// frame's travel — on a quick release the fade wandered 8pt and the
    /// blur was recomposed on every frame of it. The box's bounds and the
    /// type inside it are laid out together (`bannerBox.layoutIfNeeded()`).
    private var restingDrop: CGFloat {
        max(0, bannerBox.bounds.height - (bannerHeightConstraint?.constant ?? bannerBox.bounds.height))
    }

    /// `view`'s frame in the box's resting space — the stretch taken off.
    private func restingFrame(of view: UIView) -> CGRect {
        view.convert(view.bounds, to: bannerBox).offsetBy(dx: 0, dy: -restingDrop)
    }

    /// Slides the image within its viewport so it lags the scroll.
    ///
    /// The header itself is moved by its top constraint, so the picture would
    /// travel with it exactly 1:1 and read as flat. Moving the image DOWN
    /// inside the box by a fraction of that travel makes it fall behind, which
    /// is the whole of the effect. The image is cut taller than the box by at
    /// least the largest offset this can produce, so no edge is ever exposed.
    ///
    /// The picture slides INSIDE `bannerView` rather than the view moving:
    /// the blur's masks belong to the box, where the name is, and the
    /// picture passes under them.
    private func applyBannerParallax(travelled: CGFloat) {
        let overshoot = bannerOvershoot
        bannerView.pictureOutset = UIEdgeInsets(top: overshoot, left: 0, bottom: overshoot, right: 0)
        let clamped = min(max(travelled, 0), headerTravel)
        bannerView.pictureShift = clamped * Self.bannerParallaxFraction
        // A pull-down carries the host down by the overscroll while the
        // box's top holds at the view's: the box is stretched by exactly
        // that, and the picture and its ramp only zoom (set before the
        // layout pass the offset causes).
        let stretch = max(0, -travelled)
        bannerView.stretch = stretch
        bannerRamp.stretch = stretch
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
        // The docked band is the navigation bar plus the selector that lands in
        // it. That is what still covers the list after the header has gone.
        let docked = view.safeAreaInsets.top + Self.selectorSlotHeight
        return UIEdgeInsets(
            top: max(view.safeAreaInsets.top, docked),
            left: 0, bottom: bottom, right: 0
        )
    }

    /// Hands both tabs what actually covers them.
    ///
    /// ⚠️ BOTH, not just Activity. The Discover grid has the identical defect —
    /// a 268pt portrait brick also overruns a 163pt band — so fixing the list
    /// alone would leave the grid parking its tapped tile off the screen.
    private func applyLandingOcclusion() {
        let cover = landingOcclusion
        for hosted in hostedPages {
            (hosted as? ForYouGridPage)?.setChromeOcclusion(cover)
        }
    }

    /// The height the header takes at rest — what the pages are inset by so
    /// their content starts below it rather than behind it.
    private var headerHeight: CGFloat {
        headerHost.systemLayoutSizeFitting(
            CGSize(width: view.bounds.width, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel
        ).height
    }

    /// How far the header travels before the tab bar reaches the navigation
    /// bar — the moment it docks and stops climbing.
    private var headerTravel: CGFloat {
        max(0, headerHeight - Self.selectorSlotHeight - view.safeAreaInsets.top)
    }

    /// The offset that puts a page's FIRST ROW directly under the navigation
    /// bar — a tab-bar slot further than `headerTravel`, because the pages
    /// are inset by the header's whole height, tab bar included.
    private var contentFloor: CGFloat {
        max(0, headerHeight - view.safeAreaInsets.top)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        // Idempotent per value — the pages guard their own writes.
        // The banner is re-derived rather than fixed: the chrome, the name and
        // the counters all change with the device and with Dynamic Type.
        bannerHeightConstraint?.constant = bannerHeight
        placeHeroFade()
        let header = headerHeight
        for hosted in hostedPages {
            hosted.setHostedInsets(top: header, bottom: view.safeAreaInsets.bottom)
            // Room to hold ANY position the header can be in, so a tab
            // switch moves the chrome by nothing.
            hosted.setMinimumScrollTravel(contentFloor)
        }
        // Derived from the safe area and the banner's fraction, so a rotation
        // or a size change is a different answer. Idempotent — a plain
        // assignment — and deliberately NOT re-measuring `restingBarCover`,
        // which runs during the push when the bar is already down.
        applyLandingOcclusion()
        applyHeaderOffset(hostedPages.indices.contains(activeIndex)
            ? hostedPages[activeIndex].verticalOffset : 0)
    }

    /// Moves the header from the active page's offset, and fades the
    /// identity content (banner, metrics) as it slips under the translucent
    /// navigation bar — position-driven, both directions.
    ///
    /// Negative travel is NOT clamped, deliberately (the profile's rule):
    /// a pull-down at rest carries the header down with the content, and
    /// the banner's viewport-top pin turns that travel into stretch.
    private func applyHeaderOffset(_ travelled: CGFloat) {
        headerTopConstraint?.constant = -min(travelled, headerTravel)
        applyBannerParallax(travelled: travelled)
        let alpha = Self.identityAlpha(travelled: travelled, dockLine: headerTravel)
        // The BOX, so the picture, its blur, the name and the counters fade as
        // one identity rather than the image sliding out from under its own
        // caption.
        bannerBox.alpha = alpha
    }

    /// The identity fade's ramp: opaque until the last stretch of travel,
    /// gone exactly at the dock — where the metrics would otherwise go on
    /// drawing through the transparent bar.
    static func identityAlpha(travelled: CGFloat, dockLine: CGFloat, ramp: CGFloat = 80) -> CGFloat {
        guard dockLine > 0, ramp > 0 else { return 1 }
        return min(1, max(0, (dockLine - travelled) / ramp))
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

    /// Where a page should sit, given where the screen currently is — the
    /// profile pager's rule verbatim: below the dock line the offset belongs
    /// to the SCREEN (every page must agree or the header teleports on a tab
    /// switch); above it, to the TAB (each keeps its own place, floored so
    /// its first row is never left under the chrome).
    private func alignedOffset(for index: Int) -> CGFloat {
        Self.alignedOffset(
            current: hostedPages[activeIndex].verticalOffset,
            pageOwn: hostedPages[index].verticalOffset,
            dockLine: headerTravel,
            contentFloor: contentFloor
        )
    }

    static func alignedOffset(
        current: CGFloat, pageOwn: CGFloat, dockLine: CGFloat, contentFloor: CGFloat
    ) -> CGFloat {
        guard dockLine > 0, current >= dockLine else { return current }
        return max(pageOwn, contentFloor)
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
            page.render(.loading)
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
                page.render(.failed(message: "Couldn't load this place's posts."))
                activityPage.render(.failed(message: "Couldn't load this place's posts."))
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

    /// The profile's indicator, above the header rather than inside a list —
    /// see `HeroPullToRefreshView` for why the pages carry no stock control.
    private func installPullIndicator() {
        // In the band between the safe-area top and the banner's type: the
        // header slides down past it on a pull, and it draws over the picture.
        pullIndicator.constrain(in: view) { parent in
            pullIndicator.topAnchor.constraint(equalTo: parent.safeAreaLayoutGuide.topAnchor)
            pullIndicator.leadingAnchor.constraint(equalTo: parent.leadingAnchor)
            pullIndicator.trailingAnchor.constraint(equalTo: parent.trailingAnchor)
            pullIndicator.heightAnchor.constraint(equalToConstant: Self.pullIndicatorHeight)
        }
        view.bringSubviewToFront(pullIndicator)
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
        if renderedMembers != nil {
            page.invalidateIncrementalUpdates()
            activityPage.invalidateIncrementalUpdates()
        }
        renderedMembers = members
        renders += 1
        // ⚠️ THE TWO TABS NO LONGER SHOW THE SAME POSTS, only the same place.
        // Discover is a GRID of covers and drops what has none; Activity is a
        // column of cards and keeps everything. One hydration still fans out to
        // both, so they can only disagree about what this line says they
        // disagree about.
        let gallery = Self.gallery(members)
        page.render(gallery.isEmpty
            ? .empty(.init(title: "No photos or videos here yet"))
            : .content(gallery))
        let activity = Self.activity(members)
        activityPage.render(activity.isEmpty
            ? .empty(.init(title: "Nothing has happened here yet"))
            : .content(activity))
        // ⚠️ THE WHOLE CORPUS, not the gallery's. These are the PLACE's
        // numbers, and a check-in with no photograph is still something that
        // happened here — dropping it from a total because a grid cannot draw
        // it would make the place look quieter than it is.
        likesMetric.setValue(Self.aggregatedLikes(of: members))
        renderBanner(for: Self.bannerPost(in: gallery))
    }

    /// The hero banner wears the TOP post's cover. A coverless top post (a
    /// text check-in) keeps the neutral fill — honest, and never a broken
    /// image.
    private func renderBanner(for post: GalleryPost?) {
        // A refresh whose top post kept its cover keeps the picture on screen.
        guard let url = post?.thumbnailURL, url != bannerURL else { return }
        bannerTask?.cancel()
        bannerTask = Task { [weak self] in
            guard let self, let image = try? await imagePipeline.image(for: url),
                  !Task.isCancelled else { return }
            // Remembered once it is ON the banner, so a fetch that failed is
            // tried again by the next refresh.
            bannerURL = url
            UIView.transition(
                with: bannerView, duration: 0.25, options: [.transitionCrossDissolve]
            ) {
                self.bannerView.image = image
            }
        }
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

    /// The Activity tab's corpus: every member, MOST POPULAR first (product
    /// call, 2026-09-28) — `ranked`, the same rule Discover leads with, so
    /// the two tabs agree about what the place is known for and differ only in
    /// what a grid can draw.
    ///
    /// Popularity is REACTIONS (likes), then recency, then id — `ranked`'s
    /// words, not a new formula. It is the number every other popularity
    /// surface already reads: For You's Trending, this page's banner and first
    /// tile, and the map marker's face ("its most-liked member"). Comments were
    /// not folded in: nothing else ranks by them, and a second
    /// definition here would let this list and the marker above it disagree
    /// about which post is the place's loudest.
    ///
    /// It used to be chronological (newest first). A close from the map still
    /// moves the post the viewer was on to the head of this list
    /// (`activityCardRevealOrigin`); that pin wins over the ranking for the
    /// landing it serves.
    ///
    /// Every KIND travels: a place's activity is its posts, so the cards show
    /// words, stills and video exactly as For You's own card tab does.
    static func activity(_ posts: [GalleryPost]) -> [GalleryPost] {
        ranked(posts)
    }

    /// The place's likes: every member's, summed — client-side, since
    /// counter.v1 has no place entity to ask (`dev/BACKEND_GAPS.md`). Missing
    /// values count as zero rather than poisoning the sum — a counter the
    /// read-model never projected is absence, not information.
    static func aggregatedLikes(of posts: [GalleryPost]) -> Int64 {
        posts.reduce(0) { $0 + ($1.reactionCount ?? 0) }
    }

    /// What the Discover grid currently shows, in its rendered order — for
    /// the tests that pin the popularity ranking without reaching into the
    /// page.
    var renderedPosts: [GalleryPost] { page.posts }
    /// The Activity cards as rendered, same purpose.
    var renderedActivity: [GalleryPost] { activityPage.posts }
    /// The tab strip's titles, pinned by tests against silent drift. Read off
    var tabTitles: [String] { tabBar.currentTitles }

    // MARK: - The navigation bar

    /// The bar, left to right: back chevron · selector (docked only) ·
    /// dynamic space · points balance · Follow.
    private func configureNavigationItems() {
        configureFollowButton()
        configureWalletBadge()
        applyTrailingItems()
        // ⚠️ THE ORDERING RULE WENT WITH THE CAP. The leading-selector install
        // measured the bar's whole budget to size its capsule, so the trailing
        // group had to be in place first. An accessory has no budget to
        // measure against and no group to be swept into.
        selectorAccessory = SelectorAccessory(strip: tabBar)
        // ⚠️ THE ACCESSORY GIVES NO OTHER SIGNAL. `UITabAccessory` has one
        // property and no delegate; a screen that has to know the foot chrome
        // moved — because its landing occlusion is measured against it — hears
        // it from the host's own layout pass.
        selectorAccessory?.hostView.onLayoutChanged = { [weak self] in
            self?.chromeDidMove()
        }
    }

    /// ⚠️ INDEX 0 IS THE RIGHTMOST. The pin keeps the corner it has always
    /// had and the balance sits inboard of it — the same order the map puts
    /// its coin inboard of the bell.
    ///
    /// ⚠️ EACH IN ITS OWN BUBBLE. `sharesBackground = false` is UIKit's
    /// opt-out from the one glass pill a trailing group otherwise draws
    /// around everything in it. Left sharing, a balance and a pin read as
    /// one segmented control with a divider nobody drew.
    private func applyTrailingItems() {
        let items = [followItem, walletItem].compactMap { $0 }
        for item in items { item.sharesBackground = false }
        navigationItem.rightBarButtonItems = items
    }

    /// The viewer's spendable points, in the toolbar — the fifth host of one
    /// badge (the map, For You, the profile, the post screen, and here).
    ///
    /// Built in this package rather than through the shell's
    /// `WalletBadgeInstaller`, for the reason the post screen is: a pushed
    /// screen owns its own navigation item, and what the installer exists to
    /// share — the freshness rules — is two closures here.
    private func configureWalletBadge() {
        guard let wallet else { return }
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
        let item = UIBarButtonItem(customView: walletBadge)
        item.accessibilityLabel = "Points balance"
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

    /// The trailing pin, and nothing but the pin.
    ///
    /// ⚠️ A PLAIN BAR ITEM, where this was a custom view carrying a label.
    /// The word is gone on purpose — the state is already in the fill, and a
    /// titled item is charged its whole word against the bar's budget
    /// (34pt of platter around it, measured), which is width the docked
    /// selector then does not have: measured, "Activity" came back clipped to
    /// "Activi" on a 402pt device with the label up. A glyph item costs the
    /// 44pt every glyph costs, and UIKit draws it as the same bubble the
    /// map's bell and the profile's tray wear.
    private func configureFollowButton() {
        guard let following else { return }
        let item = UIBarButtonItem(primaryAction: UIAction { [weak self] _ in
            guard let self, let following = self.following else { return }
            self.renderFollowState(following.toggle())
        })
        followItem = item
        renderFollowState(following.isFollowing())
    }

    /// One place decides both states' looks, so they can't drift: the outline
    /// pin calls, the filled one rests. The word that used to sit beside it
    /// is gone (see `configureFollowButton`), so the FILL is the whole of the
    /// state — which is why the label a screen reader hears still says both
    /// words.
    private func renderFollowState(_ isFollowing: Bool) {
        followState = isFollowing
        // A PIN: following a place pins it (the map's "pinned" filter reads
        // the same store), and the heart now means points — see
        // `PointsSymbol`.
        followItem?.image = UIImage(systemName: isFollowing ? "pin.fill" : "pin")
        followItem?.tintColor = isFollowing ? .secondaryLabel : .tintColor
        followItem?.accessibilityLabel = isFollowing
            ? "Unfollow this place" : "Follow this place"
    }

    // MARK: - Opening a tile

    private func openTile(
        at index: Int, in grid: ForYouGridPage?, showingComments: Bool = false
    ) {
        guard let grid else { return }
        let posts = grid.posts
        guard posts.indices.contains(index) else { return }
        let tapped = posts[index]
        let stream = Array(posts[index...].prefix(Self.seedWindow))
        let hero = grid.hero(for: tapped.id, in: view)
        let appearance = grid.heroAppearance(for: tapped.id)
        // The page's own card style, translated into the one the seam speaks
        // — `ExternalHeroZoomSource` makes the same trip in the other
        // direction. Two enums with the same cases on purpose: one is this
        // feature's, the other crosses the interface.
        let flightStyle: SnapFeedHeroStyle = appearance?.style == .listMedia ? .listMedia : .tile
        let origin = SnapFeedHeroOrigin(
            post: tapped,
            stream: stream,
            hasHero: hero != nil,
            cover: appearance?.cover,
            // ⚠️ ASKED, not assumed. A card's cover is a wide row, not a
            // square tile, and the literal `.tile` this used to pass was only
            // ever right because every page here was a grid. The page that
            // drew the thing knows what shape it drew.
            style: flightStyle,
            frame: { [weak grid] space in grid?.hero(for: tapped.id, in: space)?.frame },
            isOnScreen: { [weak grid] in grid?.isPostVisible(tapped.id) ?? false },
            setConcealed: { [weak grid] concealed in
                grid?.setHeroHidden(concealed, for: tapped.id)
            },
            // ⚠️ THE CARD TAKES OFF PLAYING, rather than wearing the post's
            // poster until the page has landed.
            //
            // A row on these lists is already playing under the finger that
            // taps it, and the flight used to carry the still: the clip became
            // a photograph for the length of the opening and only resumed after
            // the landing. Filmed on Activity. The card joins the row's own
            // playback as an extra surface — the row keeps rendering behind it,
            // so there is nothing to park and nothing to hand back if the
            // flight is abandoned.
            donateLiveMedia: { [weak grid] in grid?.liveFlightSurface(for: tapped.id) },
            // A TEXT post's page IS its thread, so it arrives there by being
            // tapped at all — see `SnapFeedHeroOrigin.opensComments`.
            opensComments: showingComments && tapped.kind != .text,
            depthView: { [weak grid] in grid },
            // A row with no media has nothing to fly, and `hasHero` above is
            // already false for it — which used to mean the platform's plain
            // slide, on the one surface in the app where a text post did not
            // get the window every other list gives it. This is that window.
            textReveal: textRowReveal(for: tapped, in: grid)
        )
        // Remembered for the CLOSE. A flight opened from this page has a tile
        // to go home to, which is exactly what tells that close apart from the
        // map's Case B — see `cardCloseGeometry`. Cleared when this page is the
        // screen again (`viewDidAppear`), so a stale departure can never answer
        // for a later flight that came from somewhere else.
        tileDeparture = (id: tapped.id, isActivity: grid === activityPage)
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
        return TextRevealOrigin(
            rowFrame: { [weak self] space in
                guard let self else { return nil }
                return activityPage.textRowFrame(for: anchor, in: space)
                    ?? activityPage.rowFrame(for: anchor, in: space)
            },
            captionEnd: nil,
            depthView: { [weak self] in self?.pager },
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
        if let tileDeparture {
            return tileCardCloseGeometry(dismissing: feed, departure: tileDeparture)
        }
        guard let landed = activePostID?() else { return nil }
        // Measured in the bounds the pop will run in: this page is off-stack
        // and unsized when the driver asks, and the feed's own stack is the
        // one it is about to join.
        let bounds = feed.navigationController?.view.bounds ?? feed.view.bounds
        guard let origin = activityCardRevealOrigin(sizedTo: bounds, settled: landed)
        else { return nil }
        debugLogLanding("landing \(landed.rawValue) on the FIRST Activity row")
        return TextRevealInstaller.geometry(feed: feed, origin: origin, pipeline: imagePipeline)
    }

    func clearLandingConcealment() {
        // BOTH channels, on BOTH pages: the flight hid the departure at the
        // push and only its own return puts that back, so a visit that ends on
        // a text post — closed by the card driver — would leave it blank. Which
        // page held it depends on which tab the viewer opened from, and by the
        // time this runs that is no longer a question worth asking.
        for hosted in hostedPages {
            guard let grid = hosted as? ForYouGridPage else { continue }
            grid.clearRevealConcealment()
            grid.clearHeroConcealment()
            grid.endHeroFreeze()
        }
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
        dismissing feed: UIViewController, departure: (id: PostID, isActivity: Bool)
    ) -> RevealGeometry? {
        let grid = departure.isActivity ? activityPage : page
        grid.clearHeroConcealment()
        if departure.isActivity {
            stageActivityLanding(for: departure.id, sizedTo: nil)
        } else {
            stageDiscoverLanding(revealing: departure.id, sizedTo: nil)
        }
        guard let post = grid.post(for: departure.id),
              grid.rowFrame(for: departure.id, in: grid) != nil
        else {
            debugLogLanding("no realized departure for \(departure.id.rawValue)")
            return nil
        }
        debugLogLanding("landing on its own departure \(departure.id.rawValue)"
            + " tab=\(departure.isActivity ? "activity" : "discover")")
        let anchor = departure.id
        let onList = departure.isActivity
        let origin = TextRevealOrigin(
            rowFrame: { [weak self] space in
                guard let self else { return nil }
                let grid = onList ? activityPage : page
                return grid.rowFrame(for: anchor, in: space)
            },
            // No cut on either tab: a tile has no caption to cut against, and
            // an Activity row's caption belongs to the DEPARTURE post while the
            // page being closed may be showing a different one.
            captionEnd: nil,
            depthView: { [weak self] in self?.pager },
            makeDismissStandIn: { [weak self] _ in
                guard let self else { return nil }
                // The settled post is deliberately ignored — this window closes
                // onto what the viewer opened.
                return onList
                    ? activityPage.makeDismissStandIn(for: anchor)
                    : page.makeTileStandIn(for: post, slotOf: anchor)
            },
            // ⚠️ FALSE on both tabs, for the two reasons this file already
            // gives: a full page aligned to a small tile slides most of the
            // screen's width, and a caption measured on one post cannot align
            // a page showing another.
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
            // A ROW takes the card's own rounding (nil lets the installer use
            // it); a tile takes the grid's, asked rather than restated.
            cornerRadius: onList ? nil : page.tileCornerRadius,
            // `nil` now means "this source has no ground" — see
            // `TextRevealOrigin.fill`. A list row HAS one; it is the card's.
            fill: onList ? PostGridListRowCell.cardFillColor
                : PostGridTileCell.fillColor(for: post),
            setConcealed: { [weak self] concealed in
                guard let self else { return }
                (onList ? activityPage : page).setRevealConcealed(concealed, for: anchor)
            },
            willStageDismissal: { [weak self] _ in
                guard let self else { return }
                // And again, for the same reason: the pass that SETS an offset
                // does not realize the cells at it.
                (onList ? activityPage : page).clearHeroConcealment()
                if onList {
                    stageActivityLanding(for: anchor, sizedTo: nil)
                } else {
                    stageDiscoverLanding(revealing: anchor, sizedTo: nil)
                }
            },
            dismissalDidEnd: { [weak self] committed in
                guard let self else { return }
                let grid = onList ? activityPage : page
                grid.endHeroFreeze()
                if !committed { grid.clearRevealConcealment() }
            }
        )
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
        if let settled, settled != anchor,
           activityPage.adoptPost(
               settled, intoSlotOf: anchor, orInsert: activityPage.post(for: settled)
           ) {
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
            depthView: { [weak self] in self?.pager },
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
        // ⚠️ A PASS BEFORE THE PAGER IS TOUCHED. `setActivePage` moves a
        // scroll view by PAGE WIDTH, and a pager that has never been laid out
        // has none — so the offset it computes is zero and any page but the
        // first is never brought on, whatever it was asked for. Measured (when
        // Activity was the SECOND tab): the landing row stayed unrealized on
        // the first ask and only appeared on the second, one run loop later,
        // which sent every close to the fallback slide. Kept for whichever tab
        // sits second.
        view.layoutIfNeeded()
        adoptTab(.activity)
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

    /// Puts this page on its Discover tab with `anchor`'s tile on screen.
    /// Same shape and same two layout traps as `stageActivityLanding`.
    private func stageDiscoverLanding(revealing anchor: PostID, sizedTo bounds: CGRect?) {
        loadViewIfNeeded()
        if let bounds, view.bounds.size != bounds.size { view.frame = bounds }
        view.layoutIfNeeded()
        adoptTab(.discover)
        page.beginHeroFreeze()
        page.revealPost(anchor, clearing: landingOcclusion)
        view.layoutIfNeeded()
    }

    /// Puts the header, the strip and the pager on `tab` with no animation —
    /// the landing's half of a tab tap, through the same alignment rule, so the
    /// header does not move for the switch.
    private func adoptTab(_ tab: Tab) {
        let index = Self.index(of: tab)
        if activeIndex != index {
            hostedPages[index].setVerticalOffset(alignedOffset(for: index))
            activeIndex = index
            applyHeaderOffset(hostedPages[index].verticalOffset)
            syncAutoplay()
        }
        mirrorSelection(to: index)
        pager.setActivePage(index, animated: false)
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
    /// The header's live top-constraint constant — negative while collapsed,
    /// positive under a pull-down.
    var debugHeaderConstant: CGFloat { headerTopConstraint?.constant ?? 0 }
    /// The dock line, as the coordinator computed it for this layout.
    var debugHeaderTravel: CGFloat { headerTravel }
    var debugIdentityAlpha: CGFloat { bannerBox.alpha }
    var debugBannerHeight: CGFloat { bannerHeightConstraint?.constant ?? 0 }
    var debugLandingOcclusion: UIEdgeInsets { landingOcclusion }
    var debugHeaderBottom: CGFloat { headerHost.frame.maxY }
    /// The picture's top inside the box — negative while it is cut taller.
    var debugBannerImageTop: CGFloat { bannerView.pictureFrame.minY }
    var debugHeroNameInk: UIColor { heroNameLabel.textColor }
    /// The ink the name and the counters wear on the picture.
    var debugHeroInkTones: (name: HeroInk.Tone, rank: HeroInk.Tone, likes: HeroInk.Tone) {
        (nameTone, rankTone, likesTone)
    }
    /// The banner's fade, in the view's space.
    var debugBannerFade: HeroBannerFade.Geometry? {
        bannerView.fade?.offset(by: headerHost.frame.minY)
    }
    /// The blur levels showing, in the view's space.
    var debugBannerBlurLevels: [(start: CGFloat, full: CGFloat)] {
        let top = headerHost.frame.minY
        return bannerView.debugVisibleLevels.map { ($0.start + top, $0.full + top) }
    }
    var debugBlurComposeCount: Int { bannerView.debugComposeCount }
    var debugBlurBakeCount: Int { bannerView.debugBakeCount }
    /// Where the sharp picture covers, in the view's space.
    var debugBannerPictureCover: CGRect { bannerView.convert(bannerView.debugPictureCover, to: view) }
    var debugRampLocations: [CGFloat] { bannerRamp.debugLocations }
    var debugRampAlphas: [CGFloat] { bannerRamp.debugAlphas }
    var debugBlurBakeMilliseconds: Double { bannerView.debugLastBakeMilliseconds }
    /// The banner box's frame, in the view's space.
    var debugBannerBoxFrame: CGRect { bannerBox.convert(bannerBox.bounds, to: view) }
    var debugHasBannerPicture: Bool { bannerView.image != nil }
    /// Puts a picture on the banner directly, for a test that measures the
    /// type over it — the load path is the pipeline's, tested elsewhere.
    func debugSetBannerImage(_ image: UIImage) {
        bannerView.image = image
    }
    /// WCAG contrast of the name, then each shown counter's value and
    /// caption, against the pixels rendered behind them — see
    /// `HeroInk.debugContrast`. Labelled by their text.
    func debugHeroInkContrast() -> [(String, HeroInkContrast)]? {
        view.layoutIfNeeded()
        let metrics = [rankMetric, likesMetric].filter { !$0.isHidden }
        let labels = [heroNameLabel] + metrics.flatMap(\.debugLabels)
        guard let measured = HeroInk.debugContrast(of: labels, in: bannerBox, over: Surface.page)
        else { return nil }
        return zip(labels, measured).map { ($0.text ?? "?", $1) }
    }
    /// Drives the header the way a scroll does, which the simulator cannot.
    func debugApplyHeaderOffset(_ travelled: CGFloat) { applyHeaderOffset(travelled) }
    /// Whether the name and the counters are drawn ON the banner.
    var debugIdentityRidesTheBanner: Bool {
        heroNameLabel.isDescendant(of: bannerBox)
            && (metricsBand.map { $0.isDescendant(of: bannerBox) } ?? false)
    }
    /// The name's and the counter row's frames, in the view's space.
    var debugNameFrame: CGRect { heroNameLabel.convert(heroNameLabel.bounds, to: view) }
    var debugMetricsFrame: CGRect {
        metricsBand.map { $0.convert($0.bounds, to: view) } ?? .zero
    }
    /// The rank column as drawn — nil when it is not.
    var debugRankColumn: (value: String?, caption: String?)? {
        rankMetric.isHidden ? nil : (rankMetric.accessibilityValue, rankMetric.accessibilityLabel)
    }
    /// The band's two numbers as rendered — the place's own totals, which are
    /// deliberately NOT the gallery's (see `render`).
    /// Which Activity row a dismissal from the MAP is currently aimed at. The
    /// rule it pins is a product one — always the head of the list, holding the
    /// post the viewer was on — and its violation is a page that lands
    /// scrolled to an arbitrary row, which looks like a scroll position rather
    /// than like a bug.
    var debugLandingAnchor: PostID { anchorID }
    /// The title of the tab the page is on, so a test can say "Activity"
    /// without knowing where the strip puts it.
    var debugActiveTabTitle: String { Self.tabOrder[activeIndex].title }
    /// The tab the strip's pill is on, which must agree with the page.
    var debugSelectedTabTitle: String { Self.tabOrder[tabBar.selectedIndex].title }
    /// Selects `tab` the way a settled landing does, for a test that needs the
    /// page to start somewhere else.
    func debugSelectTab(_ tab: Tab) {
        loadViewIfNeeded()
        adoptTab(tab)
    }
    /// `-maps-place-tab`'s argument: a tab's name, or its position.
    static func debugTabIndex(_ argument: String) -> Int? {
        switch argument.lowercased() {
        case "activity": index(of: .activity)
        case "discover": index(of: .discover)
        default: Int(argument).flatMap { tabOrder.indices.contains($0) ? $0 : nil }
        }
    }
    var debugLikes: Int64 { likesMetric.debugValue }
    /// How many hydrations reached the page — a refresh that brought the same
    /// members must leave it where it was.
    var debugRenderCount: Int { renders }
    /// Releases a pull on the page for `tab`, as a finger letting go does.
    /// Selects `tab` first: only the page in front answers a pull.
    func debugReleasePull(on tab: Tab, by distance: CGFloat = HeroPullToRefreshView.threshold + 40) {
        debugSelectTab(tab)
        (hostedPages[Self.index(of: tab)] as? ForYouGridPage)?.debugReleasePull(by: distance)
    }
    /// Whether the pull's spinner is still turning.
    var debugIsRefreshing: Bool { pullIndicator.debugIsRefreshing }
    /// Whether any page still carries a stock `UIRefreshControl`.
    var debugPagesCarryRefreshControl: Bool {
        page.debugHasRefreshControl || activityPage.debugHasRefreshControl
    }
    var debugIsLoading: Bool { isLoading }
    var debugHeroName: String? { heroNameLabel.text }
    /// How far the identity's foot clears the banner's edge — the invariant the
    /// old -18 constant broke the moment the selector moved onto the banner.
    ///
    /// ⚠️ THE CAPSULE IT WAS CLEARING IS NOT ON THE BANNER ANY MORE. The number
    /// is kept because the counters still need air above the picture's edge,
    /// but its stated reason is history: the selector is at the foot of the
    /// screen. Re-decide it rather than inheriting it.
    var debugIdentityClearance: CGFloat {
        bannerBox.bounds.height - (metricsBand?.frame.maxY ?? 0)
    }
    /// Drives the active page to a travel offset through the same path a
    /// finger's scroll reports through.
    func debugScrollActivePage(to offset: CGFloat) {
        hostedPages[activeIndex].setVerticalOffset(offset)
        applyHeaderOffset(hostedPages[activeIndex].verticalOffset)
    }
}
#endif

// MARK: - The hosted-header contract

/// What a page owes the floating header's coordinator: report travel, take a
/// travel offset, and reserve room. One shape for both page kinds, so the
/// coordinator rides whichever is active without caring which it is.
@MainActor
protocol PlaceProfileHostedPage: UIView {
    var onVerticalScroll: ((CGFloat) -> Void)? { get set }
    var onPullReleased: ((CGFloat) -> Void)? { get set }
    var verticalOffset: CGFloat { get }
    func setVerticalOffset(_ offset: CGFloat)
    func setHostedInsets(top: CGFloat, bottom: CGFloat)
    func setMinimumScrollTravel(_ travel: CGFloat)
}

extension ForYouGridPage: PlaceProfileHostedPage {}

// MARK: - Header pieces

/// One column of the metrics band: a compact count over its caption — the
/// profile header's metric shape, minus everything an account has and a
/// place doesn't.
private final class PlaceMetricView: UIView {
    private let valueLabel = UILabel()
    private let titleLabel = UILabel()

    init(title: String) {
        super.init(frame: .zero)
        // ⚠️ 20 AND 13 LITERAL, for the reason the hero name states: a point
        // size read back from `preferredFont` already carries the current
        // category, and re-scaling it scales it twice.
        //
        // DOWN from title2-bold (22). The name went 28 → 34, so the pair goes
        // from 28:22 — two bolds arguing about which is the headline — to
        // 34:20, which reads as a title and a measurement.
        // ⚠️ THE PROFILE'S COUNTER TYPE (headline over caption1), since the
        // row is the profile's row now: cells across the column, the same
        // shape as Followers / Following / Likes.
        valueLabel.font = .preferredFont(forTextStyle: .headline)
        valueLabel.adjustsFontForContentSizeCategory = true
        valueLabel.textColor = .label
        valueLabel.textAlignment = .center
        valueLabel.text = "—"
        // footnote, not caption1: the profile's counters are caption1 because
        // three of them share one row. Two on a full banner can afford a step.
        titleLabel.font = .preferredFont(forTextStyle: .caption1)
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.textColor = .secondaryLabel
        titleLabel.textAlignment = .center
        titleLabel.text = title
        let column = UIStackView(arrangedSubviews: [valueLabel, titleLabel])
        column.axis = .vertical
        column.spacing = Spacing.xs
        column.translatesAutoresizingMaskIntoConstraints = false
        addSubview(column)
        NSLayoutConstraint.activate([
            column.topAnchor.constraint(equalTo: topAnchor),
            column.leadingAnchor.constraint(equalTo: leadingAnchor),
            column.trailingAnchor.constraint(equalTo: trailingAnchor),
            column.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        isAccessibilityElement = true
        accessibilityLabel = title
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// The picture's ink — the counters stand on the banner's picture, as a
    /// poster's do on a profile: white or black by what is behind them
    /// (`HeroInk`), with a soft shadow of the opposite tone.
    func setInk(tone: HeroInk.Tone) {
        valueLabel.textColor = tone.primary
        titleLabel.textColor = tone.secondary
        for label in [valueLabel, titleLabel] {
            HeroInk.applyShadow(to: label, tone: tone, onPicture: 1)
        }
    }

    func setValue(_ value: Int64) {
        stored = value
        valueLabel.text = CountFormatter.compactString(for: value)
        accessibilityValue = valueLabel.text
    }

    /// A value that is not a count — the rank's "#3" — and its caption.
    func setText(_ value: String, title: String) {
        valueLabel.text = value
        titleLabel.text = title
        accessibilityLabel = title
        accessibilityValue = value
    }

    #if DEBUG
    /// The value and its caption, for the ink audit.
    var debugLabels: [UILabel] { [valueLabel, titleLabel] }
    /// The raw total, before `CountFormatter` rounds it into something a
    /// column can hold. A test asserting "57" against "57" through the
    /// formatter would pass just as well against "57.4K".
    private(set) var debugValue: Int64 = 0
    private var stored: Int64 {
        get { debugValue }
        set { debugValue = newValue }
    }
    #else
    private var stored: Int64 = 0
    #endif
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
    func setContentScrollEnabled(_ enabled: Bool) {
        pager.isPagingEnabled = enabled
    }
}
