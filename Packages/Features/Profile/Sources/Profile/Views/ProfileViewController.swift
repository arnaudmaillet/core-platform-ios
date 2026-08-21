import MediaCore
import CoreModels
import ProfileInterface
import CoreNavigation
import FeedInterface
import MapsInterface
import MediaPlayback
import DesignSystem
import PostGrid
import UIKit

final class ProfileViewController: UIViewController {
    private let viewModel: ProfileViewModel
    /// Non-nil only for the signed-in viewer's own profile (the Profile tab);
    /// nil for a profile pushed via routing, which shows no account actions.
    private let onLogout: (() -> Void)?
    /// Builds the edit form (for the viewer's own profile); the closure it
    /// receives is invoked after a successful save. Nil for other users.
    private let makeEditViewController: ((@escaping () -> Void) -> UIViewController)?
    /// Builds the account settings screen (own profile only, the gear's
    /// destination). Nil for other users.
    private let makeSettingsViewController: (() -> UIViewController)?
    /// Builds the reusable profile-switcher menu (own profile only). Nil for
    /// other users — switching is a viewer affordance.
    private let switcherFactory: ProfileSwitcherMenuFactory?
    /// Builds the followers / following screen for a subject and a starting
    /// tab. Nil when the app wasn't wired with a relationships repository, in
    /// which case the counters stay inert rather than opening an empty screen.
    private let makeRelationshipsViewController: (
        (ProfileRelationshipsViewModel.Subject, RelationshipDirection) -> UIViewController
    )?

    /// The identity block and the selector, floating above the pages.
    ///
    /// ⚠️ **Not in a scroll view.** The profile used to be one outer scroll view
    /// containing the header and a pager sized to its active page; every layout
    /// defect on this screen came from that container resizing. The pages own
    /// all vertical motion now and this host is MOVED by whichever page is being
    /// read — see `ProfileHeaderScrollCoordinator`.
    /// Passthrough, not a plain view: the header floats OVER the pages, so a
    /// container that took every touch inside its bounds would stop a drag that
    /// began on the avatar or the bio from scrolling anything. See
    /// `ScrollPassthroughView`.
    private let headerHost = ScrollPassthroughView()
    /// How far the host has been pulled up, driven by the active page's offset.
    private var headerTopConstraint: NSLayoutConstraint?
    /// The bar's see-through dress, worn only while the banner is behind it.
    private var transparentBarAppearance: UINavigationBarAppearance?
    /// Whether the bar is currently see-through.
    private var isBarTransparent = true
    /// Retained for the share sheet, which builds its own QR card (and a
    /// throwaway one to rasterize) and needs the same avatar cache.
    private let imagePipeline: ImagePipeline
    /// Supplies the share sheet's quick-send row; nil hides it.
    private let shareTargeting: (any ProfileShareTargeting)?
    private let headerView: ProfileHeaderView
    private let galleryPager: ProfileGalleryPagerView
    /// Flies a tapped post into the unified feed. Injected rather than built
    /// here: the card and the transition belong to the feed feature, and this
    /// screen only describes where the post is (see `SnapFeedHeroOrigin`).
    /// Nil leaves every tap on the plain route, which still opens the feed.
    var feedHero: (([PostID], UIViewController, SnapFeedHeroOrigin) -> Void)?
    /// Which pages this profile has. The viewer's own carries Saved and Liked;
    /// everyone else's does not, because neither pile is anybody else's to see.
    private let tabs: [ProfileTab]
    /// The gallery's format selector — the SAME `PagedTabBar` For You and
    /// Messages wear, so a viewer meets one selector in three places rather
    /// than three selectors doing one job.
    ///
    /// It lives inline, under the identity block where it belongs to the
    /// profile, and hands over to the navigation bar's title slot as the
    /// identity scrolls away — see `updateBarDocking`. Both are built in the
    /// `.navigationTitle` style: the docked size is the constrained one, and a
    /// bar that only fits in the place it is not going is no use. The inline one
    /// is then told to FILL, which spreads it across the page's column.
    ///
    /// ⚠️ **TWO instances, and this replaced one that was re-parented.** A
    /// single bar moved between the two hosts is the tidier object — it owns its
    /// selection, its lens and its badge geometry, and a second copy is a second
    /// answer to each. But one view cannot be in two places, and the hand-over
    /// is a CROSSFADE: for a quarter of a second both selectors are on screen,
    /// one shrinking away and one growing in. That is not a state a re-parented
    /// view can express at any price.
    ///
    /// What it costs is exactly the risk the old comment named, so the sync is
    /// funnelled through two places and nowhere else: `mirrorSelection(to:)` for
    /// which segment is chosen, and `setProgress` on both from the pager's own
    /// callback. Nothing else may write to either bar.
    private let inlineBar: PagedTabBar
    /// The leading-group item hosting the docked selector, for the audit.
    private var selectorBarItem: UIBarButtonItem?
    private let dockedBar: PagedTabBar
    /// Both selectors, for the writes that must reach each of them.
    private var selectorBars: [PagedTabBar] { [inlineBar, dockedBar] }
    /// Guards the mirror against its own echo: `select` fires `.valueChanged`
    /// exactly as a tap does, so mirroring a choice onto the other bar would
    /// otherwise re-enter the handler that started it.
    private var isMirroringSelection = false
    /// The source filter: one drop-down button — the native single-selection
    /// menu carries the options (checkmark on the active one), and the button
    /// shows the pick's glyph. Lazy: the menu actions capture self.
    private lazy var sourceMenuButton = GlassMenuButton(
        menu: UIMenu(options: .singleSelection, children: [
            makeSourceAction(.all, title: "All", symbol: "rectangle.stack"),
            makeSourceAction(.posts, title: "Posts", symbol: "square.and.pencil"),
            makeSourceAction(.reposts, title: "Reposts", symbol: "arrow.2.squarepath"),
            makeSourceAction(.tagged, title: "Tagged", symbol: "at")
        ]),
        accessibilityLabel: "Content source"
    )

    private func makeSourceAction(
        _ source: GalleryFilter.Source, title: String, symbol: String
    ) -> UIAction {
        UIAction(
            title: title,
            image: UIImage(systemName: symbol),
            // The checkmark starts on the user's GLOBAL preference (seeded
            // into the view model's filter), not a hardcoded default.
            state: source == viewModel.galleryFilter.source ? .on : .off
        ) { [weak self] action in
            guard let self else { return }
            self.viewModel.setGallerySource(source)
            // The icon-only button carries no system mirroring: adopt the
            // picked action's glyph (and its title for VoiceOver) by hand.
            self.sourceMenuButton.button.configuration?.image = action.image
            self.sourceMenuButton.button.accessibilityValue = action.title
        }
    }
    /// The pull indicator, above the header rather than inside a list — see
    /// `ProfilePullToRefreshView` for why the stock control could not be used.
    private let pullIndicator = ProfilePullToRefreshView()
    /// The band the spinner centres in, under the navigation bar.
    private static let pullIndicatorHeight: CGFloat = 44
    private let statusLabel = UILabel()
    /// First-load guarantee: while the skeleton screen is up, the scroll
    /// content must fill the viewport, so the gallery's shimmer rows reach
    /// the screen bottom from the very first layout pass. The pager's own
    /// fitted-height pin sits at `.defaultHigh` (750); this inequality
    /// outranks it, and the pager is the only stretchable link in the
    /// content chain — so it, not the header, absorbs the remainder. Without
    /// this, the first frames of a push can catch the pager at its floor
    /// (the fitted height converges only after the collection's first
    /// real-width pass), cropping the skeleton to a row and a half.
    private var skeletonViewportFill: NSLayoutConstraint?
    private var didSubordinatePagerToPop = false
    #if DEBUG
    /// Launch-argument hooks are one-shot; see `viewDidAppear`.
    private var hasArmedDebugHooks = false
    #endif
    /// Full-width swipe-to-dismiss, live only on the first tab — see
    /// `ProfileDismissalPolicy`. Held for the screen's lifetime; the gate is
    /// what changes, not the wiring.
    private let slideDismissal = InteractiveSlideDismissal()
    private var didInstallSlideDismissal = false
    #if DEBUG
    /// Latches the `-profile-map-pin-demo` tap to a single firing.
    private var didTapMapPinForQA = false
    /// Latches the `-profile-relationships` QA push to a single firing.
    private var didPushRelationshipsForQA = false
    #endif

    /// The own-profile settings gear; pushes `AccountSettingsViewController`.
    private var settingsItem: UIBarButtonItem?
    /// The own-profile switcher; taps present the profile-switcher menu.
    private var switcherItem: UIBarButtonItem?
    /// The relationship capsule: Follow / Following.
    ///
    /// **A stock titled item — deliberately not `UIBarButtonItem(customView:)`,
    /// and not a `UIButton` of any kind.** Two independent reasons, and both
    /// have bitten this screen:
    ///
    /// 1. *Rendering.* The iOS 26 bar wraps every item in its own Liquid Glass
    ///    capsule. A glass-configured button hosted as a custom view stacks a
    ///    second material inside that capsule — a visible double-background
    ///    bleed — and `.done`/prominent styling floods the capsule with tint.
    ///    Handing UIKit a title and letting it draw the chrome is the only way
    ///    to get exactly one capsule.
    /// 2. *Transitions.* A custom view is opaque to the bar's push/pop
    ///    choreography: UIKit can cross-fade and slide items it owns, but a
    ///    hosted view is just a subview it has to carry, which is what makes
    ///    custom bar items snap while native ones interpolate.
    ///
    /// Identity matters as much as nativeness. `applyNavigationState` runs on
    /// every `viewWillAppear`, including the one a *pop* delivers — and a fresh
    /// `UIBarButtonItem` handed to the bar mid-transition is not a state change
    /// UIKit can animate either: it discards the outgoing item's rendered
    /// content and lays the replacement out from scratch, so the capsule
    /// arrives empty and its title fades in after the transition settles.
    /// Recorded at 30fps on the pop back from the relationships screen: six
    /// frames of a blank glass pill, then a late text fade. So this item is
    /// created once and only ever retitled.
    ///
    /// The tap is a `UIAction` primary action rather than a target/selector —
    /// same native item, no `@objc` shim.
    private lazy var followActionItem = UIBarButtonItem(
        title: "Follow",
        image: nil,
        primaryAction: UIAction { [weak self] _ in self?.viewModel.toggleFollow() },
        menu: nil
    )

    /// The item set last handed to the navigation item, so a re-entrant apply
    /// that resolves to the same items touches nothing. `UIBarButtonItem`
    /// inherits `NSObject`'s identity equality, so this compares by reference —
    /// exactly the question being asked ("are these the same items?").
    private var appliedBarItems: [UIBarButtonItem]?

    /// The loaded profile's @handle — the screen title once known. Stashed so
    /// `viewWillAppear` can bind the bar from current state before the push
    /// animation starts, whenever the data beat the transition.
    private var currentHandle: String?

    private var followButtonState: ProfileViewModel.FollowButton = .hidden

    /// Where the filter tray lives, and with it whether a bottom bar survives
    /// below this screen. Fixed at construction — the host knows, and the screen
    /// cannot work it out for itself (a nav root inside a tab bar and a pushed
    /// screen look identical from in here).
    private let trayPlacement: ProfileTrayPlacement
    /// True between an account switch and the incoming profile landing. While
    /// set, the skeleton is withheld and updates cross-dissolve.
    private var isSwitchingProfile = false

    private enum Metrics {
        /// Between the identity block and the selector.
        ///
        /// Deliberately TIGHTER than the gap below it. The selector belongs to
        /// the profile it sits under — same margins, same column — and what it
        /// needs separating from is the content it filters. Equal gaps made it
        /// read as a third thing floating between two others.
        static let selectorTopGap: CGFloat = 10
        /// Between the selector and the first row it filters.
        static let selectorBottomGap: CGFloat = 16
        /// The height the selector's slot holds in the scrolling column,
        /// whether or not the selector is in it — the bar's own height plus the
        /// breathing room beneath it, taken from the bar rather than restated.
        static let selectorSlotHeight = PagedTabBar.Style.navigationTitle.height + selectorBottomGap
        /// How long the hand-over between the two selectors takes.
        ///
        /// Short enough to feel like a state change rather than a performance —
        /// this fires mid-scroll, with the viewer's attention on the content
        /// coming up, not on the chrome.
        static let dockTransition: TimeInterval = 0.26
        /// How small the leaving selector shrinks to, and how small the arriving
        /// one starts.
        ///
        /// Shallow on purpose. A deep zoom reads as an object flying towards the
        /// viewer; this is one control changing places, and at 0.88 the scale is
        /// felt as crispness rather than seen as travel.
        static let dockZoomScale: CGFloat = 0.88
        /// How long the outgoing profile takes to dissolve into the new one.
        static let switchCrossfade: TimeInterval = 0.28
        /// The bottom tray's own height.
        static let inlineTrayHeight = InlineFilterTrayView.height
        /// Between the tray and the bar beneath it, so the two glass rows read
        /// as separate objects rather than one stack.
        static let inlineTraySpacing = InlineFilterTrayView.spacingBelow
    }

    /// Holds the selector's place in the scrolling column whether or not the
    /// selector is currently in it.
    ///
    /// ⚠️ **The slot keeps its height when the bar leaves.** Docking moves one
    /// view between two parents; if the vacated slot collapsed, the content
    /// below would jump up by its height at the exact moment the viewer is
    /// scrolling through it, and the scroll would fight the layout for as long
    /// as they stayed near the threshold.
    private let inlineBarSlot = UIView()
    /// Whether the selector is currently in the navigation bar.
    private var isBarDocked = false
    /// The header's position at the previous docking check, so the next one can
    /// tell a scroll from a flick.
    private var lastDockingTravel: CGFloat = 0

    /// The bottom tray, holding the source filter and nothing else now that the
    /// format tabs have moved to the top of the screen.
    ///
    /// The two filters answer different questions and are asked at different
    /// rates: the format tabs are navigation — tapped and swiped constantly —
    /// while the source is a setting, chosen once and then left alone. Splitting
    /// them puts each where its traffic is, and leaves the source where this
    /// screen's viewers have always reached for it.
    private lazy var inlineTrayView: UIView = InlineFilterTrayView(trailing: sourceMenuButton)

    init(
        viewModel: ProfileViewModel,
        imagePipeline: ImagePipeline,
        videoPlayback: VideoPlaybackController? = nil,
        shareTargeting: (any ProfileShareTargeting)? = nil,
        onLogout: (() -> Void)?,
        makeEditViewController: ((@escaping () -> Void) -> UIViewController)? = nil,
        makeSettingsViewController: (() -> UIViewController)? = nil,
        switcherFactory: ProfileSwitcherMenuFactory? = nil,
        makeRelationshipsViewController: (
            (ProfileRelationshipsViewModel.Subject, RelationshipDirection) -> UIViewController
        )? = nil,
        identityStub: ProfileIdentityStub? = nil,
        trayPlacement: ProfileTrayPlacement = .navigationToolbar
    ) {
        self.trayPlacement = trayPlacement
        self.viewModel = viewModel
        self.onLogout = onLogout
        self.makeEditViewController = makeEditViewController
        self.makeSettingsViewController = makeSettingsViewController
        self.switcherFactory = switcherFactory
        self.makeRelationshipsViewController = makeRelationshipsViewController
        self.imagePipeline = imagePipeline
        self.shareTargeting = shareTargeting
        headerView = ProfileHeaderView(imagePipeline: imagePipeline)
        let tabs = viewModel.isOwnProfile ? ProfileTab.ownTabs : ProfileTab.publicTabs
        self.tabs = tabs
        galleryPager = ProfileGalleryPagerView(
            imagePipeline: imagePipeline, tabs: tabs, videoPlayback: videoPlayback
        )
        inlineBar = PagedTabBar(titles: tabs.map(\.title), style: .navigationTitle)
        dockedBar = PagedTabBar(titles: tabs.map(\.title), style: .navigationTitle)
        super.init(nibName: nil, bundle: nil)

        // Only for the toolbar-hosted tray, which owns the bottom of the screen
        // and would otherwise stack with the tab bar. Safe with the standard pop
        // gesture (chat thread precedent); the feed-pushed contexts hide the bar
        // manually anyway, where this flag is a no-op.
        //
        // A tab root asks for `.aboveBottomSafeArea` instead, and must NOT hide
        // the bar — that bar is how the viewer leaves. Deciding it from the same
        // value that decides the tray keeps the two facts from drifting apart:
        // hiding the bar and hosting the tray in the toolbar are the same
        // statement about what owns the bottom of the screen.
        hidesBottomBarWhenPushed = trayPlacement == .navigationToolbar

        // Seed the navigation chrome from the origin's synchronous identity
        // slice: the title and relationship button are populated from the
        // very first layout pass, so the push animation carries a finished
        // toolbar. The async load only confirms or corrects this — it never
        // *introduces* the chrome.
        if let identityStub {
            currentHandle = "@" + identityStub.handle
        }
        // Frame-1 default for the relationship capsule when the origin didn't
        // know the follow state: "Follow" on another user's profile (the
        // statistical prior — most viewed profiles aren't followed), "Edit
        // Profile" on surfaces that are the viewer's own by construction. If
        // the relationship read disagrees, the capsule cross-fades in place.
        if identityStub?.isSelf == true || makeEditViewController != nil {
            // Own profile: Edit from frame 1. Checked BEFORE any follow hint,
            // because "do I follow myself" is not a question — a stub that
            // carried one anyway must not seed a Follow capsule here.
            followButtonState = .edit
        } else if let isFollowing = identityStub?.isFollowing {
            followButtonState = isFollowing ? .following : .follow
        } else if makeEditViewController != nil {
            followButtonState = .edit
        } else {
            followButtonState = .follow
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        // Selector-based, so UIKit drops it with this object — no token to hold
        // and no `deinit` to remember.
        NotificationCenter.default.addObserver(
            self, selector: #selector(activeProfileDidChange(_:)),
            name: .activeProfileDidChange, object: nil
        )
        configureNavigationBar()
        // Compose the bar before first layout so the push animation carries a
        // finished toolbar (the title and action slot fill in when the data
        // resolves, riding the same transition if one is still running).
        applyNavigationState()
        configureViews()

        viewModel.onPhaseChange = { [weak self] phase in
            self?.render(phase)
        }
        viewModel.onFollowButtonChange = { [weak self] state in
            guard let self else { return }
            self.followButtonState = state
            self.headerView.configureAction(state)
            // The relationship usually resolves while the push/present is
            // still animating; bind the bar inside the transition so the
            // toolbar composes during the animation, not after it.
            self.alongsideTransition { $0.applyNavigationState() }
        }
        viewModel.onMapPinButtonChange = { [weak self] state in
            self?.headerView.configureMapPin(state)
        }
        headerView.makeMapPinMenu = { [weak self] in
            self?.makeMapFavoriteMenu() ?? UIMenu()
        }
        headerView.onMessageTapped = { [weak self] in
            self?.viewModel.messageTapped()
        }
        headerView.onEditTapped = { [weak self] in
            self?.pushEditProfile()
        }
        headerView.onWebsiteTapped = { url in
            UIApplication.shared.open(url)
        }
        headerView.onQRCodeTapped = { [weak self] in
            self?.presentShareSheet()
        }
        headerView.onRelationshipsTapped = { [weak self] direction in
            self?.pushRelationships(direction)
        }
        configureMoreMenu()
        viewModel.onActionResult = { [weak self] result in
            self?.render(result)
        }
        viewModel.onDismissRequested = { [weak self] in
            self?.leaveAfterBlock()
        }
        viewModel.onLoadSettled = { [weak self] in self?.isSwitchingProfile = false }
        viewModel.onGalleryChange = { [weak self] snapshot in
            self?.galleryPager.render(snapshot)
        }
        galleryPager.onItemTapped = { [weak self] post, stream in
            guard let self else { return }
            let window = stream.isEmpty ? [post] : stream
            // ⚠️ EVERY tap goes through the hero seam, including the ones with
            // no hero to fly.
            //
            // It used to branch here: no geometry meant no flight, and no
            // flight meant falling out of the feature entirely onto
            // `AppRoute.postStream` — a bare push with no dismissal gesture, no
            // tab-bar hide and no projection. That branch was written as "the
            // animation degrades", but what actually degraded was the screen:
            // text-only posts opened under the tab bar, empty, and could not be
            // swiped away at all.
            //
            // The choice of presentation belongs to the feed, which owns both
            // the card and the dismissal — so this screen says only what it
            // has, and `hasHero` is the whole of what it knows about flying.
            guard let feedHero else {
                // No composition root wired the seam (previews, tests). The
                // route is still the honest answer there — and it is the only
                // caller left that has to settle for it.
                viewModel.galleryItemTapped(post.id, stream: window.map(\.id))
                return
            }
            // Asked ONCE, at tap time, where the answer is unambiguous: the
            // viewer just touched this cell, so it is realized by definition
            // and a nil geometry can only mean "no media", never "scrolled
            // away". The closures below re-ask the transient question for as
            // long as the flight needs it.
            let geometry = galleryPager.heroGeometry(for: post.id)
            let origin = SnapFeedHeroOrigin(
                post: post,
                stream: window,
                hasHero: geometry != nil,
                cover: geometry?.cover,
                style: geometry?.isTile == true ? .tile : .listMedia,
                frame: { [weak self] container in
                    // Re-measured, not captured: the grid scrolls itself clear
                    // of the chrome while the post is open, so the rect the
                    // dismissal flies home to is not the one it left from.
                    //
                    // The coordinate space is re-resolved with it. It is the
                    // ACTIVE page's collection view, and the geometry above is
                    // already read from whichever page is active — capturing one
                    // and re-asking the other could describe two different pages.
                    guard let self,
                          let space = self.galleryPager.heroCoordinateSpace,
                          let current = self.galleryPager.heroGeometry(for: post.id)
                    else { return nil }
                    return space.convert(current.rect, to: container)
                },
                isOnScreen: { [weak self] in
                    self?.galleryPager.heroGeometry(for: post.id) != nil
                },
                setConcealed: { [weak self] concealed in
                    self?.galleryPager.setHeroConcealed(concealed, for: post.id)
                },
                depthView: { [weak self] in self?.galleryPager },
                // A text-only post has no media to fly, and until now that
                // meant a plain push here while For You opened the same post
                // as a window. One post, one screen, two transitions depending
                // on where the viewer tapped it. This is the description that
                // ends that; everything it does not mention — the rounding,
                // the fill, the veil, the cut — is the installer's, so the two
                // surfaces cannot drift apart.
                //
                // Offered for EVERY post, not only text ones. `hasHero`
                // decides which presentation runs, and a media post never
                // reaches the reveal; a row that turns out not to be a text
                // row answers nil from `textRowFrame` anyway.
                textReveal: TextRevealOrigin(
                    rowFrame: { [weak self] space in
                        self?.galleryPager.textRowFrame(for: post.id, in: space)
                    },
                    // Read ONCE, at tap, for the reason the geometry above is:
                    // the viewer just touched this cell, so it is realized by
                    // definition. `applyPendingReveal` may scroll it clear of
                    // the header while the post is up, and a row that scrolled
                    // out cannot answer.
                    captionEnd: galleryPager.textRowCaptionEnd(for: post.id),
                    depthView: { [weak self] in self?.galleryPager },
                    captionTop: galleryPager.textRowCaptionTop(for: post.id),
                    // The gallery's own concealment, which the media hero
                    // beside this already drives — one mechanism, two kinds of
                    // flight.
                    setConcealed: { [weak self] concealed in
                        self?.galleryPager.setHeroConcealed(concealed, for: post.id)
                    },
                    // No inset to pin, unlike For You's grid: these pages run
                    // `contentInsetAdjustmentBehavior = .never` for their whole
                    // life because the header floats over them, so the value
                    // the landing is measured against cannot drift under the
                    // transition. And the row has already settled — the pager
                    // applies its pending reveal on `viewDidDisappear`, which
                    // is before any of this is asked.
                    dismissalDidEnd: { [weak self] committed in
                        // The card is alone again: bring in the two things it
                        // has and the page never did — its metric line and its
                        // affordance. Deferred by a turn, because this fires
                        // immediately before `completeTransition` re-parents
                        // the grid and cancels animations just started on its
                        // cells.
                        guard committed else { return }
                        DispatchQueue.main.async {
                            self?.galleryPager.fadeInRevealedFurniture(for: post.id)
                        }
                    }
                )
            )
            feedHero(window.map(\.id), self, origin)
        }
        // Swipe ↔ tabs: a settled swipe adopts the tab and mirrors the
        // selectors; a tab tap records it and pages.
        galleryPager.onPageSettled = { [weak self] tab in
            guard let self else { return }
            self.adoptTab(tab)
            if let index = self.tabs.firstIndex(of: tab) {
                self.mirrorSelection(to: index)
            }
        }
        configureFilterTray()
        // Mirror the (possibly stub-seeded) relationship into the header's
        // tray, so Message visibility agrees with the toolbar from the start.
        headerView.configureAction(followButtonState)
        // The pin, by contrast, is NOT seeded from the stub: a stub says who
        // this is and whether the viewer follows them, never whether they are
        // pinned. It arrives when the view model has actually asked.
        headerView.configureMapPin(viewModel.mapPinButton)
        render(.loading)
        viewModel.viewDidLoad()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        // ⚠️ **The dock is not optional on a tab ROOT.** Whatever hid it — a post
        // that flew out of this grid, a flight caught and reversed, a pop this
        // screen never heard about — the invariant is that a root profile on
        // screen has a tab bar under it. Asserted here rather than at each of the
        // paths that can hide it, because the failure is total: no dock, no way
        // to leave, and no gesture that brings it back.
        //
        // ⚠️ …but "on screen" is a question a scrub has not answered yet.
        //
        // UIKit runs this when an interactive pop BEGINS, not when it commits,
        // so a drag released below the threshold reaches here on a screen that
        // is about to be covered again. Asserting the dock unconditionally put
        // the bar back over a post that then sprang back to full screen, with
        // nothing left to take it away — the completed-pop callbacks correctly
        // never fire for a cancel. See `TabBarRevealPolicy`, which the For You
        // grid has consulted for this since it hit the identical failure.
        if navigationController?.viewControllers.first === self,
           tabBarController?.isTabBarHidden == true {
            switch TabBarRevealPolicy.timing(
                // This screen owns no flight object — a post opened from here is
                // presented by the feed feature, which restores the bar on its
                // own completed return. False makes a non-interactive tap-back
                // reveal immediately, which is what it did before and is right.
                hasActiveFlight: false,
                isTransitioning: transitionCoordinator != nil,
                isInteractive: transitionCoordinator?.isInteractive == true
            ) {
            case .immediately, .drivenByFlight:
                revealDock(animated: animated)
            case .whenTransitionCommits:
                revealDockIfTransitionCommits()
            }
        }
        // Re-bind the bar synchronously BEFORE the transition animates: any
        // state that resolved since viewDidLoad (fast mock loads, cached
        // profiles, returning from a pushed child) is fully populated here,
        // so the title and Follow item ride the push natively instead of
        // popping in after it.
        applyNavigationState()
        presentFilterToolbar()
        // ⚠️ On every appearance, not once. The saved pile is mutable from
        // outside this screen — the feed's bookmark button writes to the same
        // store — so a Saved tab bound at load would be stale the first time
        // the viewer saved something and came back to look at it.
        viewModel.loadSavedPosts()
    }

    /// Puts the dock back, idempotently.
    ///
    /// The guard is what makes it safe to call from more than one place: the
    /// feed's own completed-return restore can arrive before or after this, and
    /// two animated reveals of an already-visible bar is a flicker.
    private func revealDock(animated: Bool) {
        guard let tabBarController, tabBarController.isTabBarHidden else { return }
        tabBarController.tabBar.alpha = 1
        tabBarController.setTabBarHidden(false, animated: animated)
    }

    /// Defers the dock to the far side of a scrub — and only if the finger
    /// meant it.
    ///
    /// Both blocks run for a CANCELLED transition too, which is the entire
    /// point: that is the case that strands the bar over a post that stayed.
    /// The release is where the outcome is known and the pop's tail is still
    /// running, so the bar arrives WITH the screen rather than onto it; the
    /// second is the backstop for a gesture the system cancels outright, and is
    /// idempotent against the first.
    private func revealDockIfTransitionCommits() {
        guard let coordinator = transitionCoordinator else { return }
        coordinator.notifyWhenInteractionChanges { [weak self] context in
            guard TabBarRevealPolicy.shouldReveal(afterTransitionCancelled: context.isCancelled)
            else { return }
            self?.revealDock(animated: true)
        }
        coordinator.animate(alongsideTransition: nil) { [weak self] context in
            guard TabBarRevealPolicy.shouldReveal(afterTransitionCancelled: context.isCancelled)
            else { return }
            self?.revealDock(animated: true)
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        // Stops as this screen is covered — including by the post it just
        // opened, whose own player is what should be heard.
        galleryPager.setAutoplayActive(false)
        concealFilterToolbar()
    }

    /// The post has finished covering this screen, so the tapped tile can be
    /// brought clear of the chrome without anyone seeing it move.
    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        // Not `viewWillDisappear`: that fires as the transition begins, while
        // the grid is still visible behind an expanding hero card.
        galleryPager.applyPendingReveal()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        #if DEBUG
        verifyRevealClearsSelector()
        #endif
        // Both facts are true only here: the screen owns the display AND its
        // cells are realized. Reconciling any earlier finds no candidates.
        galleryPager.setAutoplayActive(true)
        // The pager's horizontal pan yields to the stack's edge-swipe pop:
        // without this, an edge-start drag over the grid PAGES instead of
        // popping (verified in-sim) — the platform contract loses. Mid-surface
        // drags are unaffected: the edge recognizer fails immediately for
        // touches that don't start in its edge zone. Deferred to first
        // appearance — the navigation controller isn't set at viewDidLoad.
        if !didSubordinatePagerToPop, let pop = navigationController?.interactivePopGestureRecognizer {
            didSubordinatePagerToPop = true
            galleryPager.horizontalPan.require(toFail: pop)
        }
        installSlideDismissalIfNeeded()
        #if DEBUG
        // ARMED ONCE. `viewDidAppear` runs again when a pushed post is dismissed,
        // and re-running these drove a second scroll on top of the background
        // reveal, undoing it moments before any check could look. Every "the
        // reveal was reverted" reading traced back to here, not to the product.
        defer { hasArmedDebugHooks = true }
        if hasArmedDebugHooks { return }
        // Dev convenience: `-profile-overscroll` parks the scroll view in the
        // pulled-down region (no touch injection in the sim), so the banner's
        // stretch-over-overscroll behavior can be screenshotted.
        if ProcessInfo.processInfo.arguments.contains("-profile-overscroll") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                self?.galleryPager.debugOverscroll(by: 140)
            }
        }
        // Dev convenience: `-profile-layout-audit` prints the resolved header
        // view tree (frames included) once content has settled — numeric
        // spacing audits without pixel-measuring screenshots.
        if ProcessInfo.processInfo.arguments.contains("-profile-layout-audit") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                guard let self else { return }
                let description = self.headerView
                    .perform(Selector(("recursiveDescription")))?
                    .takeUnretainedValue()
                print("PROFILE-LAYOUT-AUDIT\n\(description.map(String.init(describing:)) ?? "unavailable")")
            }
        }
        // Dev convenience: `-profile-menu-audit` prints the "..." menu the
        // current state resolves to, and fires the copy action so the toast is
        // screenshottable. The menu is the one thing on this screen no launch
        // argument can otherwise reach — it opens on a tap, and the sim has no
        // touch injection.
        if ProcessInfo.processInfo.arguments.contains("-profile-menu-audit") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                guard let self else { return }
                let titles = self.moreMenuElements().flatMap { element -> [String] in
                    guard let group = element as? UIMenu else { return [element.title] }
                    return ["—"] + group.children.map(\.title)
                }
                print("PROFILE-MENU-AUDIT canModerate=\(self.viewModel.canModerate) "
                    + "isBlocked=\(self.viewModel.isBlocked) items=\(titles)")
                self.copyProfileLink()
            }
        }
        let arguments = ProcessInfo.processInfo.arguments
        // Dev convenience: `-profile-follow-tap` fires the nav-bar Follow /
        // Following item through its own primary action ~2s in, and prints the
        // state either side. A bar item takes no simulated touch, so this is
        // how the item's wiring is verified at all.
        // Dev convenience: `-profile-edit-privacy` pushes the editor and then
        // its Privacy row, which sits behind two taps the simulator can't
        // deliver.
        if arguments.contains("-profile-edit-privacy") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                self?.pushEditProfile()
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                    self?.qaOpenPrivacy()
                }
            }
        }
        if arguments.contains("-profile-follow-tap") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                self?.qaTapFollowItem()
            }
        }
        // Dev convenience: `-profile-relationships [following]` opens the
        // followers / following screen once the profile has loaded — it lives
        // behind a tap on the counter row, which the simulator can't deliver.
        // Combine with `-profile-relationships-tab` / `-...-action` (read by
        // the destination) to drive the tab switch and a row's button.
        // Once per screen, not once per appearance: `viewDidAppear` fires again
        // when the relationships screen pops back, and re-pushing there made
        // the QA run loop between the two forever.
        // `-profile-map-pin-demo`: taps the map-pin bubble once the button has
        // actually appeared, which needs BOTH the relationship read and the
        // pin read to land — the simulator delivers no taps, and a fixed delay
        // here would fire into a hidden button on a slow run. Pair with
        // `-open-profile <id>` for a profile the viewer follows.
        if arguments.contains("-profile-map-pin-demo"), !didTapMapPinForQA {
            didTapMapPinForQA = true
            pollForMapPinButton()
        }
        if let index = arguments.firstIndex(of: "-profile-relationships"), !didPushRelationshipsForQA {
            didPushRelationshipsForQA = true
            let direction: RelationshipDirection =
                arguments.dropFirst(index + 1).first == "following" ? .following : .followers
            // Polled, not a single fixed delay: the push needs a loaded
            // profile (it hands the subject's privacy state over), and under
            // `-mock-latency` — the very flag you'd combine this with to
            // screenshot the destination's skeleton — the profile isn't loaded
            // a second and a half in, so a one-shot attempt silently no-ops.
            func attempt(_ remaining: Int) {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                    guard let self else { return }
                    // Retry rather than bail on a transient miss: this used to
                    // `return` whenever the profile wasn't topmost at that exact
                    // instant, which killed the whole chain if the tick landed
                    // mid-transition — an intermittently empty recording.
                    let isTop = self.navigationController?.topViewController === self
                    if isTop, self.viewModel.relationshipsSubject != nil {
                        self.pushRelationships(direction)
                    } else if remaining > 0 {
                        attempt(remaining - 1)
                    }
                }
            }
            attempt(30)
        }
        // `-profile-tab <activity|gallery|short|saved|liked>` selects a tab.
        // The choice PERSISTS across launches, so without this a scripted run
        // inherits whatever the last one left — which is how a video-autoplay
        // check ended up on the text-only page.
        if let position = arguments.firstIndex(of: "-profile-tab"),
           position + 1 < arguments.count {
            let wanted = arguments[position + 1]
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                guard let self,
                      let index = tabs.firstIndex(where: { $0.title.lowercased() == wanted })
                else { return }
                selectTab(at: index)
            }
        }
        // `-header-dock-demo`: docks and undocks the selector on a timer, ANIMATED,
        // so the hand-over can be recorded. A bar item's system capsule is not
        // ours to fade, so whether the pill pops or crossfades is a question only
        // frames can answer.
        // `-profile-probe-item`: a PLAIN 80x36 view as a leading bar item. If even
        // this is not hosted, the fault is this surface's leading group and not
        // anything about the selector's host.
        if arguments.contains("-profile-probe-item") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) { [weak self] in
                guard let self else { return }
                let swatch = UIView(frame: CGRect(x: 0, y: 0, width: 80, height: 36))
                swatch.backgroundColor = .systemRed
                swatch.translatesAutoresizingMaskIntoConstraints = true
                let probeItem = UIBarButtonItem(customView: swatch)
                var leading = navigationItem.leftBarButtonItems ?? []
                leading.append(probeItem)
                navigationItem.leftBarButtonItems = leading
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    print("[dock] PROBE plainItemHosted=\(swatch.window != nil) "
                        + "frame=\(swatch.frame) leftCount=\(self.navigationItem.leftBarButtonItems?.count ?? -1)")
                }
            }
        }
        if arguments.contains("-profile-dock-trace") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 6.0) { [weak self] in
                guard let self else { return }
                let nav = navigationController
                let siblings = (navigationItem.leftBarButtonItems ?? []).map { item -> String in
                    let kind = item.customView.map { String(describing: type(of: $0)) } ?? "system"
                    return "\(kind)/win=\(item.customView?.window != nil)/hidden=\(item.isHidden)"
                }.joined(separator: " + ")
                print("[dock] STATE left=\(navigationItem.leftBarButtonItems?.count ?? -1) "
                    + "right=\(navigationItem.rightBarButtonItems?.count ?? -1) "
                    + "isBarDocked=\(isBarDocked) intrinsicW=\(dockedBar.intrinsicContentSize.width) "
                    + "hostFrame=\(selectorBarItem?.customView?.frame ?? .zero) "
                    + "chain=\(chainDescription(selectorBarItem?.customView)) "
                    + "siblings=[\(siblings)] "
                    + "navBar=\(navigationController?.navigationBar.frame ?? .zero) "
                    + "isTopVC=\(navigationController?.topViewController === self) "
                    + "stack=\(navigationController?.viewControllers.map { String(describing: type(of: $0)) } ?? []) "
                    + "parent=\(parent.map { String(describing: type(of: $0)) } ?? "none") "
                    + "barHidden=\(navigationController?.isNavigationBarHidden == true) "
                    + "barInWindow=\(navigationController?.navigationBar.window != nil) "
                    + "barAlpha=\(navigationController?.navigationBar.alpha ?? -1) "
                    + "barIsHidden=\(navigationController?.navigationBar.isHidden == true) "
                    + "barSubviews=\(navigationController?.navigationBar.subviews.count ?? -1) "
                    + "presented=\(presentedViewController.map { String(describing: type(of: $0)) } ?? "none") "
                    + "tabNav=\(tabBarController?.selectedViewController.map { String(describing: type(of: $0)) } ?? "none")")
            }
        }
        if arguments.contains("-header-dock-demo") {
            for (index, docked) in [true, false, true].enumerated() {
                DispatchQueue.main.asyncAfter(deadline: .now() + 4.0 + Double(index) * 2.0) {
                    [weak self] in self?.debugAnimateBarDocked(docked)
                }
            }
        }
        // `-profile-swipe-demo <peak>` drives the full-width dismissal the way
        // a finger would. The simulator injects no touches, and the gate this
        // exercises — whole surface on the first tab, edge only after it — is
        // otherwise only observable with a thumb.
        if let position = arguments.firstIndex(of: "-profile-swipe-demo"),
           position + 1 < arguments.count, let peak = Double(arguments[position + 1]) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
                guard let self else { return }
                let allowed = ProfileDismissalPolicy.allowsFullWidthDismissal(
                    activeIndex: galleryPager.activePageIndex,
                    isPushed: navigationController?.viewControllers.first !== self
                )
                print("[profile-swipe] tab=\(galleryPager.activePageIndex) fullWidthAllowed=\(allowed)")
                Task { @MainActor [slideDismissal] in
                    await slideDismissal.debugPerformSwipe(peakProgress: CGFloat(peak))
                }
            }
        }
        // `-profile-scroll <points>` scrolls the active page before anything
        // else, so a tile can be driven while it is tucked UNDER the header —
        // at rest nothing is, since the content starts below it, and that is
        // the only state the header-alignment bug appears in.
        if let position = arguments.firstIndex(of: "-profile-scroll"),
           position + 1 < arguments.count, let points = Double(arguments[position + 1]) {
            var attempts = 0
            func attempt() {
                attempts += 1
                // Polls: a fixed delay clamps to the top while the page is still
                // loading and the run then tests a tile at rest, which is the
                // one state the alignment bug cannot appear in.
                if galleryPager.debugSetVerticalOffset(CGFloat(points)) { return }
                if attempts < 60 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: attempt)
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: attempt)
        }
        // `-profile-bar-tree`: the navigation bar's real subview tree. The own
        // profile reports a bar that is in a window, not hidden, at alpha 1, with
        // items in its arrays — and renders none of them. Only the tree can say
        // whether UIKit built wrappers for them at all.
        if arguments.contains("-profile-bar-tree") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 8.0) { [weak self] in
                guard let bar = self?.navigationController?.navigationBar else { return }
                func walk(_ view: UIView, depth: Int) {
                    let pad = String(repeating: "  ", count: depth)
                    print(String(format: "[bar-tree] %@%@ frame=%.0f,%.0f %.0fx%.0f alpha=%.2f hidden=%@ subs=%d",
                                 pad, String(describing: type(of: view)),
                                 view.frame.minX, view.frame.minY, view.frame.width, view.frame.height,
                                 view.alpha, view.isHidden ? "Y" : "N", view.subviews.count))
                    guard depth < 6 else { return }
                    for sub in view.subviews { walk(sub, depth: depth + 1) }
                }
                walk(bar, depth: 0)
            }
        }
        // `-profile-dock`: drives the header all the way to DOCKED, and says so.
        //
        // ⚠️ **A scroll that lands is not a dock.** `-profile-scroll <points>`
        // stops when the offset applies — which happens while a page is still
        // loading and clamps short of the dock line — so runs meant to exercise
        // the docked selector quietly never docked, the bar had nothing to host,
        // and the audit reported "no selector on this bar". That was read as a
        // hosting failure twice, and two fixes were judged against it.
        //
        // This polls on the STATE the test is about, retries the scroll each
        // time, and prints either SETTLED or GAVE UP — so a run can never be
        // silently meaningless.
        if arguments.contains("-profile-dock") {
            var attempts = 0
            func attempt() {
                attempts += 1
                // Far past any dock line; the page clamps to whatever it has.
                _ = galleryPager.debugSetVerticalOffset(3_000)
                if isBarDocked {
                    print("[dock] SETTLED docked=true attempts=\(attempts) "
                        + "selectorHosted=\(dockedBar.window != nil)")
                    return
                }
                if attempts < 160 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: attempt)
                } else {
                    print("[dock] GAVE UP docked=false attempts=\(attempts) "
                        + "offsets=\(galleryPager.debugVerticalOffsets) "
                        + "hasGallery=\(viewModel.hasGallery)")
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: attempt)
        }
        // `-profile-open-post <index>` taps a gallery tile once the gallery has
        // content. The sim injects no touches, and a tile tap is the only way
        // to reach either the open destination or the background reveal.
        if let position = arguments.firstIndex(of: "-profile-open-post"),
           position + 1 < arguments.count,
           let index = Int(arguments[position + 1]) {
            var attempts = 0
            func attempt() {
                attempts += 1
                // Polls rather than firing on a fixed delay: the gallery's
                // first page has to land, and a fixed delay silently no-ops
                // under `-mock-latency`.
                if galleryPager.debugSelectItem(at: index) { return }
                if attempts < 60 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: attempt)
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: attempt)
        }
        // Dev convenience: `-profile-share-demo [activity]` opens the QR share sheet once
        // the profile has loaded — the sheet is behind a tap on the header's
        // QR bubble, which the sim can't deliver.
        if let index = arguments.firstIndex(of: "-profile-share-demo") {
            // `activity` chains into the system share sheet and `send` into a
            // DM with the first quick-send target — both go through the real
            // dismiss-then-hand-off path, so the handoff itself is what gets
            // screenshotted, not a shortcut around it.
            let chained = arguments.dropFirst(index + 1).first
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                self?.presentShareSheet()
                let chainedActions = [
                    "activity", "send", "search", "search-empty", "search-cancel",
                    "search-send", "search-scroll", "search-lower"
                ]
                guard chainedActions.contains(chained ?? "") else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                    let sheet = self?.presentedViewController as? ProfileShareViewController
                    switch chained {
                    case "activity": sheet?.qaHandOffToSystemShare()
                    case "send": sheet?.qaSendToFirstTarget()
                    case "search-scroll":
                        sheet?.qaBeginSearch("a")
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                            sheet?.qaScrollResults(by: 90)
                        }
                    case "search-lower":
                        // Lower the keyboard, then report whether Cancel is
                        // still usable and fire it — the exact sequence that
                        // used to strand the user in search.
                        sheet?.qaBeginSearch("a")
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                            sheet?.qaLowerKeyboard()
                            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                                // Reported separately: a missing sheet and an
                                // unusable button are different failures, and
                                // `?? false` conflated them.
                                print("CANCEL-USABLE sheet=\(sheet != nil) "
                                    + "usable=\(sheet.map(\.qaCancelIsUsable).map(String.init) ?? "n/a")")
                                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                                    sheet?.qaTapCancel()
                                }
                            }
                        }
                    default:
                        // `search-empty` opens search WITHOUT typing, which is
                        // the suggestions-on-entry state.
                        sheet?.qaBeginSearch(chained == "search-empty" ? "" : "a")
                        // `search-cancel` also backs out again, so the
                        // restored state is screenshottable.
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                            switch chained {
                            case "search-cancel": sheet?.qaCancelSearch()
                            case "search-send": sheet?.qaSelectFirstResult()
                            default: break
                            }
                        }
                    }
                }
            }
        }
        // Dev convenience: `-profile-block-demo [account]` runs the block
        // command for real (mock `social_graph.v1/Block`, then the
        // confirmation toast and the pop), skipping only the confirmation
        // sheet — which needs a tap the simulator can't deliver. Pass
        // `account` to exercise the account-wide fan-out.
        if let index = arguments.firstIndex(of: "-profile-block-demo") {
            let scope: ProfileBlockScope =
                arguments.dropFirst(index + 1).first == "account" ? .account : .profile
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                self?.viewModel.block(scope)
            }
        }
        #endif
    }

    override func viewSafeAreaInsetsDidChange() {
        super.viewSafeAreaInsetsDidChange()
        // With a transparent bar the view extends under the chrome, so the top
        // safe-area inset is exactly the status-bar + navigation-bar height the
        // header's overlay content must clear.
        headerView.chromeTopInset = view.safeAreaInsets.top
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        // The scroll view opts out of automatic inset adjustment (the banner
        // must start at y = 0), so the bottom safe area — which includes the
        // toolbar while it shows — is re-added by hand, plus breathing room
        // so the grid's last row scrolls clear of the transparent bar's glass
        // capsules.
        // Inline placement puts the tray inside this view rather than in the
        // navigation toolbar, so its height is ours to clear as well — the
        // toolbar's was already folded into `safeAreaInsets.bottom` by UIKit.
        let trayClearance = trayPlacement == .aboveBottomSafeArea && viewModel.hasGallery
            ? Metrics.inlineTrayHeight + Metrics.inlineTraySpacing
            : 0
        let bottom = view.safeAreaInsets.bottom + (viewModel.hasGallery ? 8 : 0) + trayClearance
        galleryPager.setContentBottomInset(bottom)
        // The pages are inset by the header floating over them, so their content
        // starts below it rather than behind it. Applied here because the
        // header's height is only known once it has laid out.
        galleryPager.setContentTopInset(headerHeight)
        galleryPager.setStickyTopOcclusion(stickyTopOcclusion)
        // Every tab must be able to absorb the header's whole travel, or a
        // short one cannot hold the position a long one was left at and the
        // header follows the clamp back up. See `setMinimumScrollTravel`.
        galleryPager.setMinimumScrollTravel(contentTravel)
        // Where the header stops, and so where the offset stops being the
        // screen's business and starts being each tab's own. See the pager's
        // `alignedOffset`.
        galleryPager.setSharedTravel(dockLine: headerTravel, contentFloor: contentTravel)
    }

    /// Opens the followers / following lists on the tapped counter's tab.
    ///
    /// Pushed onto this screen's own stack rather than routed: the destination
    /// is another Profile surface, and `AppRoute` exists for *cross-feature*
    /// navigation (the rows inside it do route — each one opens someone else's
    /// profile). Gated on a loaded profile, because the subject it hands over
    /// carries the privacy state.
    private func pushRelationships(_ direction: RelationshipDirection) {
        guard let makeRelationshipsViewController,
              let subject = viewModel.relationshipsSubject
        else { return }
        navigationController?.pushViewController(
            makeRelationshipsViewController(subject, direction), animated: true
        )
    }

    #if DEBUG
    /// Waits for the map-pin bubble to be OFFERED, then taps it — through the
    /// same callback a finger fires, so what QA exercises is the real path.
    ///
    /// Polled rather than delayed for the reason the relationships push
    /// documents: two reads have to land first (the relationship, then the pin
    /// state), and under `-mock-latency` a fixed delay fires into a button
    /// that is not there yet — reporting a working feature by pressing
    /// nothing.
    private func pollForMapPinButton(attempt: Int = 0) {
        guard attempt < 40 else {
            print("[profile] map-pin demo: the button never appeared")
            return
        }
        guard viewModel.mapPinButton != .hidden else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                self?.pollForMapPinButton(attempt: attempt + 1)
            }
            return
        }
        print("[profile] map-pin demo: state was \(viewModel.mapPinButton)")
        printMapFavoriteMenu(stage: "before")
        // A value after the flag drives the MUTUAL's path — the menu rows,
        // which a simulator cannot open (no taps, and `UIMenu` needs one).
        // Bare, it is the plain follower's tap.
        let arguments = ProcessInfo.processInfo.arguments
        let choice = arguments.firstIndex(of: "-profile-map-pin-demo")
            .map { $0 + 1 }
            .flatMap { $0 < arguments.count ? arguments[$0] : nil }
            .flatMap { value -> Set<MapFavoriteCategory>? in
                switch value {
                case "dock": [.dock]
                case "following": [.following]
                case "friends": [.friends]
                case "all": [.dock, .following, .friends]
                case "none": []
                default: nil // the next launch flag, not a value
                }
            }
        if let choice {
            viewModel.setMapCategories(choice)
        } else {
            // Bare: the dock is the rail every followed profile has and the
            // one visible without selecting a primary.
            viewModel.toggleMapCategory(.dock)
        }
        print("[profile] map-pin demo: state now \(viewModel.mapPinButton)")
        printMapFavoriteMenu(stage: "after")
    }

    /// Prints the checklist the CURRENT state resolves to — the rows and their
    /// checkmarks. The menu opens on a tap and the simulator has none, so this
    /// is the only way a scripted run can tell a ticked row from an unticked
    /// one; the alternative is asserting the rows exist and hoping the marks
    /// followed. Same instrument as `-profile-menu-audit` for the "..." menu.
    private func printMapFavoriteMenu(stage: String) {
        guard viewModel.mapPinButton != .hidden else {
            print("[profile] map-pin menu (\(stage)): none — no star on this profile")
            return
        }
        let rows = mapFavoriteMenuActions()
            .map { "\($0.title)=\($0.state == .on ? "on" : "off")" }
        print("[profile] map-pin menu (\(stage)): \(rows.joined(separator: " "))")
    }

    /// Opens the editor's Privacy row from QA. Reaches through the pushed
    /// editor rather than building the screen here, so what is verified is the
    /// real wiring and not a second path to the same class.
    private func qaOpenPrivacy() {
        let editor = navigationController?.topViewController
        (editor as? EditProfileViewController)?.qaOpenPrivacy()
    }
    #endif

    /// The mutual's rail menu: a two-row CHECKLIST, Friends and Following,
    /// each an independent toggle showing whether the profile is on that rail.
    ///
    /// Two rows, not three. Two rails have four states, and two checkmarks
    /// show all four and reach any of them in a tap — including "both", which
    /// an explicit Both row used to spell a second time. That row also had to
    /// mean two different things depending on state it could not itself show
    /// (add both, or clear both), which is exactly the ambiguity a checkmark
    /// does not have.
    ///
    /// `.keepsMenuPresented` because a checklist that closes after one tick
    /// makes setting both rails a two-open chore. The rows are rebuilt as the
    /// state changes — `configureMapPin` reassigns the menu on every
    /// publication — so the marks track what was just chosen.
    ///
    /// Deferred, so the rows resolve when the menu OPENS rather than when the
    /// button was configured: the star is reconfigured on every state change,
    /// and a menu captured then would be one edit out of date the moment the
    /// viewer changed something.
    private func makeMapFavoriteMenu() -> UIMenu {
        UIMenu(children: [UIDeferredMenuElement.uncached { [weak self] completion in
            completion(self?.mapFavoriteMenuActions() ?? [])
        }])
    }

    /// The checklist's rows for the CURRENT state, apart from the menu that
    /// hosts them — the same split `moreMenuElements` uses, and for the same
    /// reason: a `UIMenu` opens on a tap, the simulator has none, and this is
    /// what `-profile-map-pin-audit` prints instead of guessing.
    private func mapFavoriteMenuActions() -> [UIAction] {
        let current = viewModel.mapPinButton.categories
        var rows: [(MapFavoriteCategory, String, String)] = [
            (.dock, "Map Dock", "pin"),
            (.following, "Following Filter", "person.badge.plus")
        ]
        // Friends is OMITTED for someone who is not a mutual, not shown
        // disabled: a greyed row invites a tap that can never work and
        // explains nothing about why. The view model refuses the write anyway
        // — this is the same rule, said in the place the viewer reads.
        if viewModel.mapPinButton.includesFriends {
            rows.append((.friends, "Friends Filter", "person.2"))
        }
        return rows.map { category, title, symbol in
            let action = UIAction(
                title: title,
                image: UIImage(systemName: symbol),
                state: current.contains(category) ? .on : .off
            ) { [weak self] _ in
                self?.viewModel.toggleMapCategory(category)
            }
            action.attributes = .keepsMenuPresented
            return action
        }
    }

    private func pushEditProfile() {
        guard let makeEditViewController else { return }
        // Pushed onto the profile's own stack, not presented: back / edge-swipe
        // returns here. Edits are per-field (each pushes its own screen), so a
        // save refreshes the profile underneath but does NOT pop the editor —
        // the user leaves the list themselves when done.
        let editViewController = makeEditViewController { [weak self] in
            self?.viewModel.refresh()
        }
        navigationController?.pushViewController(editViewController, animated: true)
    }

    // MARK: - Overflow menu

    /// Installs the see-more bubble's menu. The children are built at OPEN
    /// time through an uncached deferred element (the feed's "..." precedent),
    /// not at wiring time: whether the moderation group belongs, and whether it
    /// reads Block or Unblock, depends on a relationship that usually resolves
    /// after this runs and can change while the screen is up.
    private func configureMoreMenu() {
        headerView.setMoreMenu(UIMenu(children: [
            UIDeferredMenuElement.uncached { [weak self] completion in
                completion(self?.moreMenuElements() ?? [])
            }
        ]))
    }

    private func moreMenuElements() -> [UIMenuElement] {
        // Sharing needs a loaded handle; until then the menu is honestly empty
        // rather than offering an action that would no-op.
        var groups: [UIMenuElement] = []
        if viewModel.shareCard != nil {
            groups.append(UIMenu(options: .displayInline, children: [
                UIAction(title: "Share", image: UIImage(systemName: "square.and.arrow.up")) {
                    [weak self] _ in self?.presentShareSheet()
                },
                UIAction(title: "Copy Link", image: UIImage(systemName: "link")) {
                    [weak self] _ in self?.copyProfileLink()
                }
            ]))
        }
        // Own profile (and the pre-relationship window) offers no moderation:
        // you cannot block or report yourself, and guessing is worse than
        // waiting — the menu is rebuilt on the next open either way.
        guard viewModel.canModerate else { return groups }

        let blocked = viewModel.isBlocked
        groups.append(UIMenu(options: .displayInline, children: [
            UIAction(
                title: blocked ? "Unblock" : "Block",
                image: UIImage(systemName: blocked ? "hand.raised.slash" : "hand.raised"),
                // Unblocking is a restorative action, so it sheds the
                // destructive red that blocking earns.
                attributes: blocked ? [] : .destructive
            ) { [weak self] _ in
                guard let self else { return }
                // Unblocking is harmless and reversible — it goes straight
                // through; blocking asks first, and asks how far it reaches.
                if blocked {
                    self.viewModel.unblock()
                } else {
                    self.confirmBlock()
                }
            },
            UIAction(
                title: "Report",
                image: UIImage(systemName: "flag"),
                attributes: .destructive
            ) { [weak self] _ in self?.presentReportReasons() }
        ]))
        return groups
    }

    /// Opens the unified share surface — the QR sheet — rather than jumping
    /// straight to the system share sheet. Both the header's QR bubble and the
    /// menu's Share land here, so there is exactly one answer to "share this
    /// profile"; the system sheet is reachable from inside it.
    private func presentShareSheet() {
        guard let card = viewModel.shareCard else { return }
        let sheet = ProfileShareViewController(
            card: card,
            imagePipeline: imagePipeline,
            targeting: shareTargeting,
            // Read HERE, where there is a window: the sheet has none until it
            // is already on screen, and reading it there made the corners snap
            // after the presentation animation instead of riding it.
            deviceCornerRadius: ScreenGeometry.cornerRadius(behind: view),
            // The sheet is full-width on iPhone, so this is its width for the
            // frames before it has been laid out.
            fallbackWidth: view.bounds.width
        )
        // Both escape hatches come back HERE, after the sheet has dismissed
        // itself: the system sheet would otherwise stack on top of this one,
        // and a pushed thread would land behind it.
        sheet.onSystemShare = { [weak self] card, image in
            self?.presentActivitySheet(for: card, image: image)
        }
        sheet.onSendToTarget = { [weak self] target, card in
            self?.viewModel.sendProfile(card, to: target)
        }
        present(sheet, animated: true)
    }

    /// The system share sheet, opened once the QR sheet is gone. Two items:
    /// the link (carrying the metadata that gives the sheet a branded header)
    /// and the rendered card — the image is what makes Save Image and image
    /// targets work, which is why this feature needs no photo-library
    /// permission of its own.
    private func presentActivitySheet(for card: ProfileViewModel.ShareCard, image: UIImage) {
        let source = ProfileShareItemSource(card: card, icon: image)
        let activity = UIActivityViewController(activityItems: [source, image], applicationActivities: nil)
        activity.popoverPresentationController?.sourceView = headerView.moreButtonAnchor
        present(activity, animated: true)
    }

    private func copyProfileLink() {
        guard let link = viewModel.shareLink else { return }
        // Both slots: `.url` is what other apps paste as a rich link, `.string`
        // is what plain-text fields read. Setting only the former leaves a
        // Notes paste empty.
        UIPasteboard.general.url = link
        UIPasteboard.general.string = link.absoluteString
        ToastView.present("Link copied", symbol: "link", in: view)
    }

    /// Block is destructive and, here, one-way out of the screen — so it asks
    /// first. Named with the handle so it can't be answered on autopilot.
    ///
    /// An action sheet rather than an alert, because the question is not
    /// yes/no but *how far*: this app treats one account as owning several
    /// profiles (the switcher is a first-class affordance), so blocking one
    /// handle can leave the same person reaching the viewer from an alias.
    /// Two destructive options read as a scope choice; an alert's OK/Cancel
    /// shape would have to hide one of them behind a second step.
    private func confirmBlock() {
        let handle = viewModel.handle ?? "this user"
        let sheet = UIAlertController(
            title: "Block \(handle)?",
            message: "They won't be able to find your profile or message you, and you'll stop seeing their posts. They aren't notified.\n\nBlocking the account also blocks any other profiles it owns.",
            preferredStyle: .actionSheet
        )
        // The narrow, predictable action leads: it is what "Block" meant
        // before this choice existed, and it is the one that can't overreach.
        sheet.addAction(UIAlertAction(title: "Block \(handle)", style: .destructive) { [weak self] _ in
            self?.viewModel.block(.profile)
        })
        sheet.addAction(UIAlertAction(title: "Block Account & All Profiles", style: .destructive) { [weak self] _ in
            self?.viewModel.block(.account)
        })
        sheet.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        sheet.popoverPresentationController?.sourceView = headerView.moreButtonAnchor
        present(sheet, animated: true)
    }

    /// `moderation.v1.OpenCase` carries a policy category, so the report asks
    /// for one rather than filing everything as "other" — a category-less
    /// report is near-useless to the moderation queue.
    private func presentReportReasons() {
        let handle = viewModel.handle ?? "this profile"
        let sheet = UIAlertController(
            title: "Report \(handle)",
            message: "Why are you reporting this profile?",
            preferredStyle: .actionSheet
        )
        for reason in ProfileReportReason.allCases {
            sheet.addAction(UIAlertAction(title: reason.title, style: .default) { [weak self] _ in
                self?.viewModel.report(reason)
            })
        }
        sheet.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        sheet.popoverPresentationController?.sourceView = headerView.moreButtonAnchor
        present(sheet, animated: true)
    }

    /// Reports the outcome of a menu command. Confirmations are toasts (the
    /// action is already done — an alert would only demand a second tap);
    /// failures are alerts, because a failed block or report is something the
    /// user must know to retry.
    private func render(_ result: ProfileViewModel.ActionResult) {
        switch result {
        case .blocked(let handle, let profileCount):
            // Says what was actually blocked, not what was asked for: an
            // account-scoped block can only reach the aliases the fleet let us
            // see, so claiming "and all their profiles" would be a promise the
            // client can't keep (see `ProfileBlockScope`).
            let message = profileCount > 1
                ? "Blocked \(handle) and \(profileCount - 1) more"
                : "Blocked \(handle)"
            // Hosted on the navigation controller's view, not this screen's:
            // the block pops this view controller in the same turn, and a toast
            // parented here would leave with it.
            ToastView.present(message, symbol: "hand.raised.fill", in: navigationController?.view ?? view)
        case .unblocked(let handle):
            ToastView.present("Unblocked \(handle)", symbol: "hand.raised.slash.fill", in: view)
        case .reported:
            ToastView.present("Report sent", in: view)
        case .failed(let message):
            let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "OK", style: .default))
            present(alert, animated: true)
        }
    }

    /// Leaves the blocked profile: pop when pushed (the common case — a profile
    /// reached by routing), dismiss when presented. A tab-root profile is left
    /// standing, but it can't get here: own profiles can't be blocked.
    private func leaveAfterBlock() {
        // An open menu-spawned alert would otherwise ride out the pop.
        presentedViewController?.dismiss(animated: false)
        if let nav = navigationController, nav.viewControllers.count > 1 {
            nav.popViewController(animated: true)
        } else if presentingViewController != nil {
            dismiss(animated: true)
        }
    }

    // MARK: - Setup

    /// The banner runs under the navigation area, so the bar is transparent
    /// while the header is at the scroll edge (white title over the banner's
    /// top scrim) and snaps back to the system bar once content scrolls up
    /// underneath it.
    private func configureNavigationBar() {
        // A custom leading item silently disables the navigation controller's
        // interactive pop gesture (the feed had to build a whole replacement
        // pan for that reason). The profile must keep the native edge swipe in
        // every pushed context, so any leading item an owner installs (the
        // sheet flow's bell today) supplements the back button instead of
        // replacing it. Harmless at a stack root, where no back button exists.
        navigationItem.leftItemsSupplementBackButton = true
        let transparent = UINavigationBarAppearance()
        transparent.configureWithTransparentBackground()
        transparent.titleTextAttributes = [.foregroundColor: UIColor.white]
        transparentBarAppearance = transparent
        navigationItem.scrollEdgeAppearance = transparent
        navigationItem.standardAppearance = UINavigationBarAppearance()

        // Account actions only exist for the viewer's own profile. (`onLogout`
        // is retained for the Account Settings screen, which will host Log Out.)
        guard onLogout != nil else { return }
        // Settings gear — the viewer's account entry point. A plain trailing
        // item (no leading item, so it never disturbs the edge-swipe pop),
        // tinted `.label` to read as primary dark chrome over the banner.
        let settings = UIBarButtonItem(
            image: UIImage(systemName: "gearshape"),
            primaryAction: UIAction { [weak self] _ in self?.pushSettings() }
        )
        settings.tintColor = .label
        settings.accessibilityLabel = "Settings"
        settingsItem = settings

        // Profile switcher — the leading item, opposite the gear (see
        // `applyNavigationState` for why the leading slot is free here).
        // Tapping presents the shared switcher menu; the switch itself is
        // picked up through `.activeProfileDidChange`, so this screen refreshes
        // whichever switcher was used.
        if switcherFactory != nil {
            let switcher = UIBarButtonItem(image: UIImage(systemName: "person.2"), menu: UIMenu(children: []))
            switcher.tintColor = .label
            switcher.accessibilityLabel = "Switch Profile"
            switcherItem = switcher
            // Pre-load profiles + avatars, then set a SYNCHRONOUS menu — its
            // content lands in the first frame, not popped in after the popover.
            reloadSwitcherMenu()
        }
    }

    /// Pre-fetches the switcher snapshot and installs a synchronous menu on the
    /// switcher item. Re-run after a switch so the active marker updates.
    ///
    /// `onSwitch` is empty on purpose. Refreshing is driven by
    /// `.activeProfileDidChange` instead, so it happens no matter WHICH switcher
    /// was used — this screen's own, or the Profile tab's long-press menu, which
    /// is built by the shell and cannot call back into here.
    private func reloadSwitcherMenu() {
        guard let switcherFactory, let switcherItem else { return }
        Task { [weak self] in
            await switcherFactory.reload()
            switcherItem.menu = switcherFactory.makeMenu(
                onSwitch: {},
                onAddProfile: { [weak self] in self?.presentAddProfilePlaceholder() }
            )
        }
    }

    /// The active profile changed — from any switcher anywhere.
    ///
    /// Refetches unconditionally, including on someone ELSE's profile: the
    /// viewer changed, so the follow state and relationship button this screen
    /// shows are now answers to a different question, not just the identity at
    /// the top.
    @objc private func activeProfileDidChange(_ notification: Notification) {
        // Cache-first: a profile already seen renders on THIS turn, and the
        // fetch behind it becomes a silent revalidation. A miss has nothing
        // truthful to show for the new identity, so it redacts rather than
        // leaving the previous profile's name and numbers on screen.
        // Armed BEFORE the seed: `revalidate` publishes cached content on this
        // same turn, so the stagger has to be in place already or the cached
        // profile snaps in. It is closed out by `onLoadSettled`, NOT by a
        // phase arriving — a revalidation that agrees with the cache publishes
        // no phase at all, and hanging the reset off one that may never come
        // is what stranded this screen in a skeleton.
        isSwitchingProfile = true
        if !viewModel.revalidate(after: ActiveProfileChange.profileID(from: notification)) {
            // Nothing known about the new identity: bones are the honest state,
            // and their un-redact reveal is the animation — no stagger over it.
            isSwitchingProfile = false
            headerView.setRedacted(true)
        }
        // Re-read the snapshot so the menu's active marker moves to the profile
        // just switched to.
        reloadSwitcherMenu()
    }

    /// Runs `changes` as a cross-dissolve while a switch is in flight, and
    /// plainly otherwise. Used for both halves of the incoming profile — the
    /// header and the gallery arrive on separate callbacks, and each dissolves
    /// over whatever it is replacing.
    private func applySwitchable(on target: UIView, _ changes: @escaping () -> Void) {
        guard isSwitchingProfile, view.window != nil else {
            changes()
            return
        }
        UIView.transition(
            with: target,
            duration: Metrics.switchCrossfade,
            options: [.transitionCrossDissolve, .allowUserInteraction, .beginFromCurrentState],
            animations: changes
        )
    }

    private func presentAddProfilePlaceholder() {
        let alert = UIAlertController(
            title: "Add Profile",
            message: "Creating a new profile isn't available yet.",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }

    private func pushSettings() {
        guard let settingsViewController = makeSettingsViewController?() else { return }
        navigationController?.pushViewController(settingsViewController, animated: true)
    }

    /// The single application point for everything the navigation bar shows —
    /// title (@handle once loaded, "Profile" until then) and the relationship
    /// action. Idempotent, driven from three places: viewDidLoad (initial
    /// composition), viewWillAppear (synchronous pre-transition bind), and the
    /// async data callbacks (via `alongsideTransition`).
    private func applyNavigationState() {
        // ⚠️ **No title.** The bar used to carry the @handle, which said again
        // what the identity block says in full a finger's width below it — and
        // once the format selector docks into the title slot, a name there
        // would be competing with the one control this screen's chrome exists
        // to hold. The handle is not lost: it is on the profile, where the
        // viewer is already looking.
        if title != nil { title = nil }
        updateActionBarItem(followButtonState)
    }

    /// Runs a navigation-bar mutation eagerly during an active transition:
    /// applied inside the transition coordinator's animation block it tracks
    /// the push/present frame-by-frame instead of snapping in after the
    /// animation completes. Outside a transition, an on-screen bar gets a
    /// short cross-dissolve (the skeleton capsule melting into Follow /
    /// Following when a slow relationship read lands late); off-screen it
    /// applies immediately.
    private func alongsideTransition(_ change: @escaping (ProfileViewController) -> Void) {
        // `animate(alongsideTransition:)` DROPS the block (returning false)
        // when the transition is already in its completion phase — the
        // coordinator is still non-nil there, so trusting its existence alone
        // loses updates that land in that window. Fall through when queueing
        // fails.
        if let coordinator = transitionCoordinator, coordinator.isAnimated,
           coordinator.animate(alongsideTransition: { [weak self] _ in
               guard let self else { return }
               change(self)
           }) {
            return
        }
        if let bar = navigationController?.navigationBar, view.window != nil {
            UIView.transition(with: bar, duration: 0.25, options: .transitionCrossDissolve) {
                change(self)
            }
        } else {
            change(self)
        }
    }

    /// Installs the nav-bar relationship action per the current state, absent
    /// until the relationship is known. Plain titled items on purpose: iOS 26
    /// wraps bar items in the bar's own neutral Liquid Glass capsule — a
    /// glass-configured custom button here would stack a second material on
    /// top of it (a visible "double background" bleed), and `.done`/prominent
    /// styling floods the capsule with tint. The own-profile overflow menu
    /// keeps its slot next to it either way.
    private func updateActionBarItem(_ state: ProfileViewModel.FollowButton) {
        // Edit is no longer a bar item — it lives in the header tray beside the
        // avatar (see `ProfileHeaderView.configureAction`), so own-profile keeps
        // only its account overflow menu here.
        // One item, retitled — never a new one. See `followActionItem`.
        //
        // `.hidden` yields no item at all. It used to install a bare custom
        // view as a placeholder pill, which was both unreachable — every path
        // into `followButtonState` sets a concrete state, the view model never
        // assigns `.hidden`, and the audit only ever logs `follow`/`following`
        // — and the one thing in this slot that UIKit could not animate across
        // a transition. An absent item is the honest native answer for "no
        // relationship applies".
        let action: UIBarButtonItem? = switch state {
        case .hidden: nil
        case .follow, .following: followActionItem
        case .edit: nil
        }
        if state == .follow || state == .following {
            let resolvedTitle = state == .follow ? "Follow" : "Following"
            if followActionItem.title != resolvedTitle {
                followActionItem.title = resolvedTitle
            }
        }
        // The switcher sits in the LEADING slot, opposite the gear.
        //
        // Safe here and only here: the item exists solely on the canonical own
        // profile, which is a tab ROOT — so there is no back button to displace
        // and no interactive pop for a leading item to interfere with. A pushed
        // profile never has one (see `ProfileFeatureBuilding.onLogout`).
        //
        // Written through the same "say nothing unless it changed" guard as the
        // trailing items: handing UIKit the identical item mid-transition is
        // what tears a capsule down and rebuilds it empty.
        // ⚠️ **The switcher rides TRAILING, beside the gear, and the leading
        // group belongs to the docked selector alone.**
        //
        // Measured, docked own profile: with the switcher in the leading group
        // BOTH leading platters came out 0x44 at the same x while the trailing
        // gear sat at 46x44 — and with the switcher absent, the selector hosted
        // correctly. Neither its empty menu (seeded with a placeholder child) nor
        // the group being rewritten (single write, `isHidden` for visibility)
        // accounted for it; two leading items are fine elsewhere, since For You
        // carries a compose glyph beside its selector.
        //
        // So the chrome moved rather than the selector: this screen's actions all
        // live at the trailing end now, which is also the layout every other
        // surface wears — leading is the selector, trailing is what you can do.
        if navigationItem.leftBarButtonItems?.isEmpty == false,
           navigationItem.leftBarButtonItems?.allSatisfy({ $0 !== selectorBarItem }) == true {
            navigationItem.leftBarButtonItems = [selectorBarItem].compactMap { $0 }
        }

        // Relationship action for other users; the gear for own profile (where
        // `action` is nil).
        var items: [UIBarButtonItem] = []
        if let action { items.append(action) }
        if let settingsItem { items.append(settingsItem) }
        // The switcher, on the own profile only — see the note above for why it
        // is not in the leading group.
        if let switcherItem { items.append(switcherItem) }
        // The load-bearing guard. A pop's `viewWillAppear` resolves to exactly
        // the item set already on the bar, and handing that same set back is
        // what used to tear the capsule down and rebuild it mid-transition.
        // Nothing changed, so nothing is said.
        guard items != appliedBarItems else { return }
        appliedBarItems = items
        #if DEBUG
        // Dev convenience: `-profile-navbar-audit` prints every *actual* bar
        // rebuild with the transition state it happened in. A rebuild logged
        // during a pop is the bug this guard exists to prevent, so the audit
        // is the regression test a recording can't be.
        if ProcessInfo.processInfo.arguments.contains("-profile-navbar-audit") {
            let phase = transitionCoordinator != nil ? "DURING-TRANSITION" : "idle"
            // `custom=` is the audit's other job: it names any item in this
            // slot that is a hosted view rather than one UIKit draws itself —
            // the shape that cannot interpolate across a bar transition. It
            // must stay 0.
            let custom = items.count(where: { $0.customView != nil })
            print("PROFILE-NAVBAR-AUDIT rebuild items=\(items.count) custom=\(custom) "
                + "state=\(followButtonState) \(phase)")
        }
        #endif
        navigationItem.rightBarButtonItems = items
    }

    #if DEBUG
    /// Fires the relationship item through its own primary action — the same
    /// closure UIKit invokes on a tap, reached from the item rather than from
    /// a copy of the call. The Follow capsule is a bar item, which the
    /// simulator cannot tap, so this is the only way to prove the wiring
    /// survived the conversion off target/action.
    private func qaTapFollowItem() {
        guard let action = followActionItem.primaryAction else {
            print("PROFILE-FOLLOW-TAP no primary action on the item")
            return
        }
        print("PROFILE-FOLLOW-TAP before=\(followButtonState) customView=\(followActionItem.customView != nil)")
        action.performWithSender(followActionItem, target: nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self else { return }
            print("PROFILE-FOLLOW-TAP after=\(self.followButtonState) title=\(self.followActionItem.title ?? "nil")")
        }
    }
    #endif


    private func configureViews() {
        // The pages fill the screen and scroll themselves; the header floats
        // over them. Order matters — the header is added second so it draws
        // above the content sliding under it.
        galleryPager.pin(to: view)

        headerHost.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(headerHost)
        let top = headerHost.topAnchor.constraint(equalTo: view.topAnchor)
        headerTopConstraint = top
        NSLayoutConstraint.activate([
            top,
            headerHost.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            headerHost.trailingAnchor.constraint(equalTo: view.trailingAnchor)
        ])

        headerView.constrain(in: headerHost) { parent in
            headerView.topAnchor.constraint(equalTo: parent.topAnchor)
            headerView.leadingAnchor.constraint(equalTo: parent.leadingAnchor)
            headerView.trailingAnchor.constraint(equalTo: parent.trailingAnchor)
        }
        // The selector's slot sits between the identity block and the gallery
        // it filters — the one place on this screen where "what you are looking
        // at" changes hands.
        inlineBarSlot.isHidden = !viewModel.hasGallery
        inlineBarSlot.constrain(in: headerHost) { parent in
            inlineBarSlot.topAnchor.constraint(
                equalTo: headerView.bottomAnchor, constant: Metrics.selectorTopGap
            )
            inlineBarSlot.leadingAnchor.constraint(equalTo: parent.leadingAnchor)
            inlineBarSlot.trailingAnchor.constraint(equalTo: parent.trailingAnchor)
            inlineBarSlot.bottomAnchor.constraint(equalTo: parent.bottomAnchor)
            inlineBarSlot.heightAnchor.constraint(
                equalToConstant: viewModel.hasGallery ? Metrics.selectorSlotHeight : 0
            )
        }

        // ⚠️ Stretchy banner, unchanged in mechanism and load-bearing in this
        // arrangement. The host is moved by its TOP CONSTRAINT rather than by a
        // transform precisely so this still works: constraints cannot see a
        // transform, and `lessThanOrEqualTo` the view's top is what pins the
        // banner while the host travels down under a pull, stretching it instead
        // of dragging it away and exposing the background behind.
        headerView.anchorBanner(toViewportTop: view.topAnchor)

        galleryPager.onVerticalScroll = { [weak self] offset in
            guard let self else { return }
            self.applyHeaderOffset(offset)
            // Negative travel is the overscroll the indicator draws from.
            self.pullIndicator.setPull(max(0, -offset))
        }
        galleryPager.onPullReleased = { [weak self] distance in
            guard let self, self.pullIndicator.shouldRefresh(releasedAt: distance) else { return }
            self.pullIndicator.beginRefreshing()
            self.viewModel.refresh()
        }
        galleryPager.onPullToRefresh = { [weak self] in self?.viewModel.refresh() }

        // Above everything, including the header it is pulled out from under:
        // the band between the safe-area top and the first content is exactly
        // where a refresh belongs, and the header slides down past it.
        pullIndicator.constrain(in: view) { parent in
            pullIndicator.topAnchor.constraint(equalTo: parent.safeAreaLayoutGuide.topAnchor)
            pullIndicator.leadingAnchor.constraint(equalTo: parent.leadingAnchor)
            pullIndicator.trailingAnchor.constraint(equalTo: parent.trailingAnchor)
            pullIndicator.heightAnchor.constraint(equalToConstant: Self.pullIndicatorHeight)
        }
        view.bringSubviewToFront(pullIndicator)

        statusLabel.font = .preferredFont(forTextStyle: .body)
        statusLabel.adjustsFontForContentSizeCategory = true
        statusLabel.textColor = .secondaryLabel
        statusLabel.textAlignment = .center
        statusLabel.numberOfLines = 0
        statusLabel.isHidden = true
        statusLabel.constrain(in: view) { parent in
            statusLabel.centerYAnchor.constraint(equalTo: parent.centerYAnchor)
            statusLabel.leadingAnchor.constraint(equalTo: parent.layoutMarginsGuide.leadingAnchor)
            statusLabel.trailingAnchor.constraint(equalTo: parent.layoutMarginsGuide.trailingAnchor)
        }
    }

    /// Wires the selector and the source filter, and puts the selector in its
    /// inline slot: a format tab records the selection and pages the gallery; a
    /// source pick re-filters every page in place.
    private func configureFilterTray() {
        guard viewModel.hasGallery else { return }

        for bar in selectorBars {
            bar.addAction(
                UIAction { [weak self, weak bar] _ in
                    guard let self, let bar else { return }
                    barSelectionChanged(bar)
                },
                for: .valueChanged
            )
            // Tapping the tab already showing is a request to go back to the top
            // of it — see the pager for which top that is.
            bar.onReselect = { [weak self] _ in self?.galleryPager.scrollActivePageToTop() }
        }
        // The lens tracks the finger, exactly as it does on the other two
        // screens that wear this bar — the pager reports a fractional position
        // every frame and the capsule interpolates against it. Both bars are
        // told, so the one that is currently invisible is already correct when
        // it fades in rather than catching up afterwards.
        galleryPager.onProgress = { [weak self] progress in
            self?.selectorBars.forEach { $0.setProgress(progress) }
        }

        placeSelectors()

        // Land on the user's global preference: tab selection and pager page
        // adopt the (possibly stored) filter before first layout, so the
        // screen OPENS there — no visible jump. The preference names a FORMAT,
        // so it can only ever land on one of the three every profile has.
        let tab = ProfileTab.format(viewModel.galleryFilter.format)
        if let index = tabs.firstIndex(of: tab) {
            mirrorSelection(to: index)
        }
        galleryPager.setActivePage(tab, animated: false)

        placeSourceTray()
    }

    /// A tap on either selector: record the format, page the gallery, and carry
    /// the choice to the other bar so the hand-over has nothing to reconcile.
    private func barSelectionChanged(_ bar: PagedTabBar) {
        guard !isMirroringSelection else { return }
        let index = bar.selectedIndex
        mirrorSelection(to: index)
        let tab = tabs[index]
        adoptTab(tab)
        galleryPager.setActivePage(tab, animated: true)
    }

    /// Arms the full-width dismissal, once, and only for a PUSHED profile.
    ///
    /// The gate is asked per gesture rather than re-installed per tab: a
    /// recognizer added and removed as the viewer pages is one that will
    /// eventually be missing when a thumb arrives.
    ///
    /// Ordering the pager behind it is safe on every tab precisely because
    /// the gate decides. Past the first tab the dismissal pan never begins,
    /// fails immediately, and the pager pages exactly as it always did.
    private func installSlideDismissalIfNeeded() {
        guard let nav = navigationController, nav.viewControllers.first !== self else { return }
        // RE-ASSERTED on every appearance, not installed once.
        //
        // A child pushed above this screen may take the stack's delegate for
        // its own transition and hand back something else — nil, historically
        // — which leaves this object installed in its own view but no longer
        // consulted. The pan still begins and still pops; UIKit just never
        // asks for the interaction controller, so the page jumps instead of
        // following the finger, and nothing ever repairs it.
        //
        // Re-installing costs nothing when it is already the delegate
        // (`install` returns early) and is the difference between a screen
        // that recovers by itself and one that stays broken for its lifetime.
        if !didInstallSlideDismissal {
            didInstallSlideDismissal = true
            slideDismissal.canBeginDismissal = { [weak self] in
                guard let self, let nav = navigationController else { return false }
                return ProfileDismissalPolicy.allowsFullWidthDismissal(
                    activeIndex: galleryPager.activePageIndex,
                    isPushed: nav.viewControllers.first !== self
                )
            }
            slideDismissal.attach(to: self)
            if let pan = slideDismissal.dismissalPan {
                galleryPager.horizontalPan.require(toFail: pan)
            }
        }
        slideDismissal.install(on: nav)
    }

    /// Records the choice and re-dresses the screen around it.
    ///
    /// ⚠️ Only a FORMAT page is a filter preference. Saved and Liked are
    /// corpora, not formats, and writing one into the stored filter would mean
    /// re-opening the profile on a tab the next profile may not even have.
    /// The source tray goes with it for the same reason: All / Posts / Reposts
    /// / Tagged are questions about what this profile published, and there is
    /// no answer to any of them about a post somebody else wrote.
    private func adoptTab(_ tab: ProfileTab) {
        if let format = tab.format {
            viewModel.setGalleryFormat(format)
        }
        // ⚠️ Only the INLINE placement has a tray to hide, and this must not
        // ask under the toolbar placement — not because the answer is wrong,
        // but because the question builds it.
        //
        // `inlineTrayView` is lazy, and its initialiser wraps
        // `sourceMenuButton` in a glass capsule and adopts it as a subview.
        // The button is the toolbar item's `customView`, so building the tray
        // takes it OFF the toolbar — and under this placement the tray is
        // never added to the hierarchy, so the button does not reappear
        // anywhere. What is left is a bar item with an empty custom view: a
        // full-width blank capsule at the bottom of the screen.
        //
        // It only showed after a TAB CHANGE, because that is the only thing
        // that reaches this line — which is why the first tab looked fine and
        // the second did not.
        guard trayPlacement != .navigationToolbar else { return }
        inlineTrayView.isHidden = tab.format == nil
    }

    /// Selects a tab the way a selector tap does — the shared path behind the
    /// debug hook and the tests, so neither exercises a shortcut around the
    /// real one.
    func selectTab(at index: Int) {
        guard tabs.indices.contains(index) else { return }
        mirrorSelection(to: index)
        adoptTab(tabs[index])
        galleryPager.setActivePage(tabs[index], animated: false)
    }

    /// Puts both selectors on the same segment.
    ///
    /// ⚠️ There is deliberately no silent `select` on `PagedTabBar` — choosing
    /// a segment announces itself, by design, so that a scripted selection
    /// drives the same path a finger does. That makes mirroring re-entrant, and
    /// the flag rather than a silent setter is what closes the loop: the echo
    /// arrives, sees the flag, and stops.
    private func mirrorSelection(to index: Int) {
        guard !isMirroringSelection else { return }
        isMirroringSelection = true
        defer { isMirroringSelection = false }
        for bar in selectorBars where bar.selectedIndex != index {
            bar.select(index)
        }
    }

    /// Puts one selector in the page's column and the other in the navigation
    /// bar's title slot, and leaves them there.
    ///
    /// ⚠️ A title view is positioned by FRAME, so the docked bar keeps
    /// autoresizing on and states its size through `sizeToFit`. The inline one
    /// is laid out by constraints. Nothing is re-parented after this, which is
    /// the point: the hand-over is two animations, not a move.
    /// Puts the docked selector's item into the leading group, or takes it out.
    ///
    /// ⚠️ **MEMBERSHIP, not `isHidden`.** Hiding the item looked right and left
    /// the selector unhosted for good: an item that is hidden when the bar lays
    /// out never has its custom view added, and un-hiding it later does not bring
    /// it back — measured as `isHidden=false`, `alpha=1`, `isBarDocked=true`,
    /// `intrinsicW=325` and a host frame of exactly zero, on the one surface of
    /// the four whose item starts hidden. Adding the item hosts it; removing it
    /// takes UIKit's glass capsule with it, which is the other thing `isHidden`
    /// was there for.
    #if DEBUG
    /// Where a view actually sits, for the state dump — "it has a superview" was
    /// not enough to tell hosted from parked in an off-screen container.
    private func chainDescription(_ view: UIView?) -> String {
        guard let view else { return "nil" }
        var names: [String] = []
        var node: UIView? = view
        var depth = 0
        while let current = node, depth < 5 {
            names.append(String(describing: type(of: current)))
            node = current.superview
            depth += 1
        }
        return names.joined(separator: "←") + "/window=\(view.window != nil)"
    }
    #endif

    private func setSelectorItemPresent(_ present: Bool) {
        // ⚠️ `isHidden`, NOT membership. Rewriting `leftBarButtonItems` is what
        // this screen's own trailing-item guard warns about — handing UIKit a
        // group again tears the platters down and rebuilds them EMPTY — and the
        // leading group here is written twice, once per appearance and once per
        // dock. Measured with both platters at 0x44 while the trailing gear sat
        // at 46x44, and with the group's other item absent the selector hosted.
        // Hiding an item leaves the group alone.
        selectorBarItem?.isHidden = !present
    }

    private func placeSelectors() {
        inlineBar.fillsWidth = true
        inlineBar.constrain(in: inlineBarSlot) { parent in
            inlineBar.topAnchor.constraint(equalTo: parent.topAnchor)
            inlineBar.leadingAnchor.constraint(
                equalTo: parent.leadingAnchor, constant: ProfileHeaderView.pageMargin
            )
            inlineBar.trailingAnchor.constraint(
                equalTo: parent.trailingAnchor, constant: -ProfileHeaderView.pageMargin
            )
        }

        // EXPERIMENT: the docked selector rides in the LEADING bar-item group,
        // beside the back button, instead of the centre title slot. One shared
        // implementation for all four hosts — see `installLeadingSelector`.
        if ProcessInfo.processInfo.arguments.contains("-profile-dock-trace") {
            print("[dock] placeSelectors hasGallery=\(viewModel.hasGallery) tabs=\(tabs.count)")
        }
        if viewModel.hasGallery {
            selectorBarItem = navigationItem.installLeadingSelector(dockedBar)
            // The inline selector owns the un-scrolled state, so the item leaves
            // the bar until the header docks. See `setSelectorItemPresent`.
            setSelectorItemPresent(isBarDocked)
        }


        applyDockedAppearance(animated: false)
    }

    /// Puts the source filter back at the bottom of the screen — in this view
    /// above the safe area when this is the Profile tab, or in the navigation
    /// controller's shared toolbar when the screen was pushed.
    private func placeSourceTray() {
        guard trayPlacement == .navigationToolbar else {
            view.addSubview(inlineTrayView)
            NSLayoutConstraint.activate([
                inlineTrayView.leadingAnchor.constraint(equalTo: view.layoutMarginsGuide.leadingAnchor),
                inlineTrayView.trailingAnchor.constraint(equalTo: view.layoutMarginsGuide.trailingAnchor),
                inlineTrayView.heightAnchor.constraint(equalToConstant: Metrics.inlineTrayHeight),
                inlineTrayView.bottomAnchor.constraint(
                    equalTo: view.safeAreaLayoutGuide.bottomAnchor,
                    constant: -Metrics.inlineTraySpacing
                )
            ])
            return
        }
        // The items must exist by the time a push starts — the feed's handover
        // rule reads the incoming screen's `toolbarItems` in its own
        // viewWillDisappear.
        toolbarItems = [.flexibleSpace(), UIBarButtonItem(customView: sourceMenuButton)]
    }

    /// What content actually passes under at the top.
    ///
    /// `safeAreaInsets.top` and nothing else. It already reaches the bottom of
    /// the navigation bar, and the docked selector rides INSIDE that bar — so
    /// adding `selectorSlotHeight` counted the selector a second time and parked
    /// every revealed card 60pt further down, leaving a blank band between the
    /// header and the card. The reveal's own 12pt padding is the only gap.
    ///
    /// Assembled rather than read off `dockedBar`'s frame: that bar is
    /// transiently out of any window during a push, so measuring it made the
    /// occlusion flip between values between reveals.
    private var stickyTopOcclusion: CGFloat {
        view.safeAreaInsets.top
    }

    #if DEBUG
    /// `-profile-verify-reveal`: does the revealed tile clear the selector, in
    /// the settled state, measured against the selector's own frame?
    ///
    /// Independent of `chromeOcclusion` on purpose. The reveal log derived its
    /// "gap" from the very inset the reveal had just applied, so it read clean
    /// whatever the tile did — including while the tile sat under the selector.
    private func verifyRevealClearsSelector() {
        guard ProcessInfo.processInfo.arguments.contains("-profile-verify-reveal") else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self, let window = view.window else { return }
            guard let tile = galleryPager.debugRevealedTileInWindow() else {
                print("[verify-reveal] no revealed tile"); return
            }
            let bar = isBarDocked ? dockedBar : inlineBar
            let selector = bar.window == nil ? .zero : bar.convert(bar.bounds, to: window)
            let navBar = navigationController?.navigationBar
            let nav = navBar?.window == nil ? CGRect.zero
                : navBar!.convert(navBar!.bounds, to: window)
            let chromeBottom = max(selector.maxY, nav.maxY)
            print(String(format:
                "[verify-reveal] tileTop=%.0f selector=%.0f…%.0f navBottom=%.0f "
                + "chromeBottom=%.0f clearance=%.0f docked=%@ %@",
                tile.minY, selector.minY, selector.maxY, nav.maxY,
                chromeBottom, tile.minY - chromeBottom,
                isBarDocked ? "Y" : "N",
                tile.minY >= chromeBottom ? "CLEAR" : "COVERED"))
        }
    }
    #endif

    /// The height the header takes when nothing is scrolled — what the pages
    /// are inset by so their content starts below it rather than behind it.
    private var headerHeight: CGFloat {
        headerHost.systemLayoutSizeFitting(
            CGSize(width: view.bounds.width, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel
        ).height
    }

    /// How far the header travels before its selector reaches the navigation
    /// bar — the moment it docks.
    private var headerTravel: CGFloat {
        max(0, headerHeight - Metrics.selectorSlotHeight - view.safeAreaInsets.top)
    }

    /// How far a tab must be able to scroll for its first row to sit directly
    /// beneath the navigation bar.
    ///
    /// ⚠️ **A slot's height further than the header travels, and the difference
    /// is the whole bug.** The pages are inset by the header's full height,
    /// selector slot included. Once the selector DOCKS, that slot is empty — its
    /// occupant is in the navigation bar — but the inset still reserves it, so a
    /// tab resting at the docked position sat a slot's height below the bar with
    /// nothing in the gap. One number was being asked two questions: when does
    /// the selector dock, and how far must the content come up. They differ by
    /// exactly the slot that changed hands.
    ///
    /// Only the FLOOR uses this. Docking still happens where it did, and the
    /// header still stops where it did — it is hidden past that point anyway.
    private var contentTravel: CGFloat {
        max(0, headerHeight - view.safeAreaInsets.top)
    }

    /// **The coordinator.** Moves the header from the active page's offset, and
    /// decides docking from the same number.
    ///
    /// ⚠️ Everything on this screen that used to be a separate mechanism is this
    /// arithmetic now. The header's position, the docking state and the
    /// tab-switch continuity all read the SAME offset, so they cannot disagree —
    /// which is what the previous architecture spent five fixes trying to
    /// arrange between a resizing container and a scroll view that clamped it.
    private func applyHeaderOffset(_ travelled: CGFloat) {
        // ⚠️ **Negative travel is not clamped, and that is the point.** The
        // floor used to be `max(travelled, 0)`, which pinned the header at rest
        // while the list bounced beneath it — pull down at the top of a profile
        // and the identity block sat still while the grid peeled away from it,
        // as though the two were unrelated screens. Letting the constant go
        // POSITIVE carries the header down by exactly the overscroll, so the
        // banner, the identity block and the selector travel with the content
        // they belong to and the whole top of the screen stretches as one.
        //
        // Only the downward end is free. The upward end still stops at
        // `headerTravel`, which is where the header has finished docking under
        // the navigation bar and must not keep climbing.
        //
        // Everything downstream of here already tolerates it: `identityAlpha`
        // clamps its ramp, and `isDocked` compares against a dock line no
        // negative offset can reach.
        headerTopConstraint?.constant = -min(travelled, headerTravel)
        applyIdentityFade(travelled: travelled)
        updateBarDocking(travelled: travelled)
        updateBarTransparency(travelled: travelled)
    }

    /// Fades the identity block out as it reaches the navigation bar, and back
    /// in on the way down.
    ///
    /// This replaced hiding the host outright at the dock line, which was two
    /// faults in one line: the block vanished in a single frame, and until that
    /// frame it went on drawing through the transparent bar — the bio's last
    /// lines sat over the status bar for the whole approach. Both are the same
    /// mistake, which is that visibility was a consequence of a STATE when it is
    /// really a function of a POSITION.
    ///
    /// ⚠️ The fade is on the identity block alone, not on its host. The host
    /// also carries the selector, which is running its own hand-over at exactly
    /// this moment; fading the pair would apply that transition twice to one of
    /// them.
    private func applyIdentityFade(travelled: CGFloat) {
        let alpha = ProfileDockThreshold.identityAlpha(
            travelled: travelled, dockLine: headerTravel
        )
        guard abs(headerView.alpha - alpha) > 0.001 else { return }
        headerView.alpha = alpha
        // ⚠️ Nothing drawn, nothing to touch. The host still spans the band
        // between the navigation bar and the content once the header has
        // travelled, and a `UIView` takes touches inside its bounds whether or
        // not it has anything to show — so left interactive it swallows scrolls
        // in that band. Hiding it used to do this for free; a faded view has to
        // say so.
        headerHost.isUserInteractionEnabled = alpha > 0.01
    }

    /// Gives the navigation bar its material back once the banner is no longer
    /// behind it.
    ///
    /// ⚠️ **UIKit normally does this for us and cannot here.** The scroll-edge
    /// appearance is chosen by watching a scroll view in the hierarchy, and this
    /// screen no longer has one at the top level — the pages own their own
    /// scrolling, one level down. Left alone the bar stays at its scroll-edge
    /// dress forever, which on this screen is fully transparent: the header's
    /// bio and link went on showing through it after the header had docked,
    /// sitting over the status bar.
    private func updateBarTransparency(travelled: CGFloat) {
        let shouldBeTransparent = travelled <= 0
        guard shouldBeTransparent != isBarTransparent else { return }
        isBarTransparent = shouldBeTransparent
        let appearance = shouldBeTransparent ? transparentBarAppearance : opaqueBarAppearance
        navigationItem.scrollEdgeAppearance = appearance
        navigationItem.standardAppearance = appearance
        navigationItem.compactAppearance = appearance
        forceNavigationBarLayout()
    }

    /// The bar's material dress, worn once the header has scrolled behind it.
    private var opaqueBarAppearance: UINavigationBarAppearance {
        let appearance = UINavigationBarAppearance()
        appearance.configureWithDefaultBackground()
        return appearance
    }

    /// Hands the selection over between the two selectors, and back.
    ///
    /// **Two coordinated halves, not a move.** The one being left shrinks
    /// slightly and fades out; the one arriving grows from the same shallow
    /// scale and fades in. They run together, so for a quarter of a second both
    /// are on screen and the eye reads one control changing places rather than
    /// two controls swapping.
    ///
    /// This is why there are two bars at all. The previous arrangement moved a
    /// single bar between the hosts and could only ever dissolve the hosts'
    /// rendered contents around the swap — a view cannot fade out of one place
    /// while fading into another.
    ///
    /// ⚠️ **Scale by TRANSFORM, and only the transform.** These capsules take
    /// their corner radius from their own bounds, so a capsule resized towards
    /// its target would need its radius re-derived every frame; a transform
    /// scales what is already drawn, corners included, and leaves the layout
    /// alone. The shallow 0.88 is also what keeps the glass honest — a deep
    /// scale magnifies the material's edge and reads as a blur artefact.
    private func applyDockedAppearance(animated: Bool) {
        let leaving = isBarDocked ? inlineBar : dockedBar
        let arriving = isBarDocked ? dockedBar : inlineBar
        let shrunk = CGAffineTransform(scaleX: Metrics.dockZoomScale, y: Metrics.dockZoomScale)

        leaving.isHidden = false
        arriving.isHidden = false
        // ⚠️ The BAR ITEM's own visibility, not just the view's. UIKit draws the
        // system glass capsule for the item; hiding the view inside it left an
        // empty pill beside the back button over the banner. `isHidden` on the
        // item is the only thing that takes the capsule with it.
        if arriving === dockedBar { setSelectorItemPresent(true) }
        // The arriving bar starts small — but ONLY when it is arriving from
        // nothing. A hand-over reversed half way through finds it already part
        // grown, and snapping it back to the start is what turns a change of
        // mind into a stutter.
        if arriving.alpha < 0.01 { arriving.transform = shrunk }

        let settle = {
            leaving.alpha = 0
            leaving.transform = shrunk
            arriving.alpha = 1
            arriving.transform = .identity
        }
        // ⚠️ Whichever bar ends up invisible is HIDDEN, not merely transparent.
        // A navigation bar owns its title view's alpha — it fades the slot's
        // contents through every push and pop and sets it back to 1 on the way
        // out — so a docked bar parked at alpha 0 comes back at full strength
        // the first time this screen is navigated to, and sits in the chrome
        // over an un-scrolled profile. `isHidden` is not a property UIKit
        // touches there. (Measured: the resting selector was fully legible in
        // the navigation bar with the banner and avatar still on screen.)
        let settleVisibility = { [weak self] in
            leaving.isHidden = true
            if leaving === self?.dockedBar { self?.setSelectorItemPresent(false) }
        }

        guard animated else {
            // ⚠️ Stop whatever is in flight FIRST. This path is taken because
            // the scroll is too fast to animate through, and a hand-over already
            // running would otherwise go on interpolating over the values just
            // written — which is the flash, arriving a frame late. Setting the
            // model values does not cancel a running animation; removing it
            // does.
            for bar in selectorBars { bar.layer.removeAllAnimations() }
            settle()
            settleVisibility()
            return
        }
        UIView.animate(
            withDuration: Metrics.dockTransition,
            delay: 0,
            options: [.curveEaseInOut, .beginFromCurrentState],
            animations: settle,
            completion: { [weak self] _ in
                guard let self else { return }
                // The dock state can have flipped back while this was running,
                // in which case a later call already owns the two bars and this
                // completion would hide the one now arriving.
                guard (isBarDocked ? inlineBar : dockedBar) === leaving else { return }
                settleVisibility()
            }
        )
    }

    #if DEBUG
    /// Where each selector currently stands, so the hand-over's resting states
    /// can be asserted rather than screenshotted. Both facts are reported —
    /// hidden AND alpha — because the distinction between them is the whole
    /// point: see `applyDockedAppearance`.
    var debugSelectorState: (
        inline: (hidden: Bool, alpha: CGFloat), docked: (hidden: Bool, alpha: CGFloat)
    ) {
        ((inlineBar.isHidden, inlineBar.alpha), (dockedBar.isHidden, dockedBar.alpha))
    }

    /// Drives the hand-over without a scroll, for the same reason: the states
    /// either side of the dock line are what matters, not the gesture that
    /// crosses it.
    func debugSetBarDocked(_ docked: Bool) {
        isBarDocked = docked
        applyDockedAppearance(animated: false)
    }

    /// The same hand-over, ANIMATED — the only way to film the transition, since
    /// `-profile-scroll` jumps the offset and a jump is deliberately not animated.
    func debugAnimateBarDocked(_ docked: Bool) {
        isBarDocked = docked
        applyDockedAppearance(animated: true)
    }

    var debugSelectedIndices: [Int] { selectorBars.map(\.selectedIndex) }

    func debugSelect(_ index: Int, onDocked: Bool) {
        (onDocked ? dockedBar : inlineBar).select(index)
    }
    #endif

    /// The nav bar caches its title view's size, so a bar arriving in or leaving
    /// the title slot has to make it re-measure — the same re-layout the other
    /// two screens force whenever a badge changes their bar's width.
    private func forceNavigationBarLayout() {
        guard let bar = navigationController?.navigationBar else { return }
        bar.setNeedsLayout()
        bar.layoutIfNeeded()
    }

    /// Docks the selector into the navigation bar once the header has travelled
    /// as far as it can, and gives it back on the way down.
    ///
    /// Both decisions — whether to change, and whether to animate the change —
    /// come from `ProfileDockThreshold`, and both depend on how fast the header
    /// is moving. See there for why speed is the input that matters.
    private func updateBarDocking(travelled: CGFloat) {
        guard viewModel.hasGallery, isViewLoaded else { return }
        // How far the header moved since the last callback. Callbacks arrive per
        // displayed frame, so this is a velocity in the only unit that matters
        // here: distance the viewer sees between one frame and the next.
        let step = travelled - lastDockingTravel
        lastDockingTravel = travelled
        let shouldDock = ProfileDockThreshold.isDocked(
            travelled: travelled, dockLine: headerTravel, step: step, wasDocked: isBarDocked
        )
        guard shouldDock != isBarDocked else { return }
        isBarDocked = shouldDock
        let animated = ProfileDockThreshold.isAnimated(step: step)
        #if DEBUG
        // Dev convenience: `-profile-dock-trace` prints every hand-over with the
        // speed that produced it. The flicker this rule exists to stop is a
        // sequence of these, not any one of them, so the log is the measurement
        // — a screenshot of a settled screen cannot show a rate.
        if ProcessInfo.processInfo.arguments.contains("-profile-dock-trace") {
            print(String(format: "[dock] %@ travelled=%.0f step=%.0f animated=%@",
                         shouldDock ? "DOCK  " : "UNDOCK", travelled, step,
                         animated ? "yes" : "no"))
        }
        #endif
        applyDockedAppearance(animated: animated)
    }


    /// Shows the shared toolbar for this screen, riding the transition. The
    /// mechanics mirror the feed's `presentToolbar`: shown non-animated so the
    /// safe area is final immediately; the *visual* entrance is an alpha fade
    /// on the transition coordinator — but only when the bar was hidden. When
    /// it arrives from another toolbar owner (pushed from the feed), the bar
    /// is already up and UIKit cross-fades the items natively.
    private func presentFilterToolbar() {
        // Inline trays are not the shared toolbar's business: nothing to show,
        // and nothing to hand off to or take from the feed.
        guard trayPlacement == .navigationToolbar else { return }
        guard viewModel.hasGallery, let nav = navigationController else { return }
        // Transparent BAR background (exactly what the feed's toolbar uses,
        // so handoffs between the two never restyle a visible bar); the
        // items' glass comes from the system's per-item capsules.
        let appearance = UIToolbarAppearance()
        appearance.configureWithTransparentBackground()
        nav.toolbar.standardAppearance = appearance
        nav.toolbar.compactAppearance = appearance
        nav.toolbar.scrollEdgeAppearance = appearance

        let wasHidden = nav.isToolbarHidden
        nav.setToolbarHidden(false, animated: false)
        nav.toolbar.alpha = 1
        if wasHidden, let coordinator = transitionCoordinator {
            nav.toolbar.alpha = 0
            coordinator.animate(alongsideTransition: { _ in
                nav.toolbar.alpha = 1
            }, completion: { _ in
                // A push cannot cancel; pin the end state either way.
                nav.toolbar.alpha = 1
            })
        }
    }

    /// The exit leg, fading the bar with whatever transition is carrying this
    /// screen away — unless the successor is a toolbar owner itself (the feed
    /// on pop-back), in which case the bar is handed over intact and the
    /// successor's own presentation reconfigures it. A cancelled interactive
    /// pop restores the alpha and keeps the bar.
    private func concealFilterToolbar() {
        // Never ours to conceal under inline placement — the bar we would be
        // hiding belongs to whichever screen actually put it up.
        guard trayPlacement == .navigationToolbar else { return }
        guard viewModel.hasGallery, let nav = navigationController, !nav.isToolbarHidden else { return }
        if let successor = nav.topViewController, successor !== self,
           successor.toolbarItems?.isEmpty == false {
            return
        }
        guard let coordinator = transitionCoordinator else {
            nav.setToolbarHidden(true, animated: false)
            return
        }
        coordinator.animate(alongsideTransition: { _ in
            nav.toolbar.alpha = 0
        }, completion: { context in
            if context.isCancelled {
                nav.toolbar.alpha = 1
            } else {
                nav.setToolbarHidden(true, animated: false)
                nav.toolbar.alpha = 1
            }
        })
    }

    // MARK: - Render

    private func render(_ phase: ProfileViewModel.Phase) {
        switch phase {
        case .loading:
            // First load renders the REAL screen in skeleton state: the
            // header redacts in place (same views, same constraints — see
            // `ProfileHeaderView.setRedacted`), and the gallery pages shimmer
            // through their own loading state until the view model's first
            // snapshot arrives. Hydration is a pure cross-fade over the very
            // frames the content will occupy — nothing can shift.
            statusLabel.isHidden = true
            galleryPager.isHidden = false
            // The HEADER is held on a switch rather than redacted: its bones'
            // shimmer sweeps left to right, and over a fast load that sweep
            // became the transition — a diagonal wipe across the identity.
            // The GALLERY still redacts, because its rows are genuinely
            // unknown until the fetch lands and bones are the honest answer.
            if !isSwitchingProfile { headerView.setRedacted(true) }
            if viewModel.hasGallery {
                skeletonViewportFill?.isActive = true
                galleryPager.render(ProfileViewModel.GallerySnapshot(
                    activity: .loading, media: .loading, short: .loading
                ))
            }

        case .content(let model):
            pullIndicator.endRefreshing()
            statusLabel.isHidden = true
            galleryPager.isHidden = false
            // Content owns its height again; the release rides the same
            // layout pass as the (dissolve-masked) gallery height snap.
            skeletonViewportFill?.isActive = false
            // Instagram-style: the @handle is the screen's title (the header
            // shows the bold display name). "Profile" only until first load.
            // Content usually lands mid-push; rebind inside the transition
            // so the bar text doesn't snap in after the animation settles.
            currentHandle = model.handle
            alongsideTransition { $0.applyNavigationState() }
            // Content first — the labels adopt their text while still
            // invisible under the bones — then the alpha-only reveal.
            // Granular on a switch: each header group dissolves on its own,
            // lightly staggered, so one identity becomes another rather than
            // the whole screen blinking over at once.
            headerView.configure(with: model, staggered: isSwitchingProfile)
            headerView.setRedacted(false, animated: view.window != nil)

        case .failed(let message):
            pullIndicator.endRefreshing()
            // Never leave the previous profile held over an error.
            galleryPager.isHidden = true
            skeletonViewportFill?.isActive = false
            headerView.setRedacted(false)
            statusLabel.text = message
            statusLabel.isHidden = false
        }
    }
}

#if DEBUG
extension ProfileViewController: DebugItemSelectable {
    /// Taps the active gallery page's first tile through its own delegate
    /// method — the path that builds a hero origin and flies.
    func debugSelectFirstItem() -> Bool {
        galleryPager.debugSelectItem(at: 0)
    }
}
#endif

#if DEBUG
extension ProfileViewController: DebugInteractivelyDismissible {
    /// Grabs this screen the way a finger would, through the same recogniser
    /// path — including its own tab gate, so a refusal here is a real refusal.
    func debugDismissInteractively() async -> Bool {
        guard slideDismissal.canBeginDismissal?() != false else { return false }
        // The RETURN VALUE matters: it reports whether the pop was driven by
        // the gesture, not merely that it happened.
        return await slideDismissal.debugPerformSwipe(peakProgress: 0.7)
    }
}
#endif
