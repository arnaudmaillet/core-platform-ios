import MediaCore
import CoreModels
import CoreStorage
import ProfileInterface
import CoreNavigation
import FeedInterface
import HeroPage
import MapsInterface
import MediaPlayback
import DesignSystem
import PostGrid
import ShareSheet
import UIKit

/// Builds For You's grid page in a style — `savesPosts` offers the save
/// control (#1273).
typealias ProfileGridPageFactory = (_ style: PostGridPageStyle, _ savesPosts: Bool) -> any PostGridPage

/// A person's hero page (`HeroPageViewController`, #1655): the container's
/// layout, travel, dock and bar dress, with the profile's own data, tabs,
/// bar items, menus and post opening.
final class ProfileViewController: HeroPageViewController<ProfileTab>, HeaderAccessoryHosting, ProfileRouteAnswering {
    /// For You's grid page (#1273, epic #1269): the profile's pages and its
    /// media gallery are For You's, so every tile behaves as For You's does.
    private let makeGridPage: ProfileGridPageFactory

    /// Internal (not private) only for the +QA hooks.
    let viewModel: ProfileViewModel
    /// Non-nil only for the signed-in viewer's own profile (the Profile tab);
    /// nil for a profile pushed via routing, which shows no account actions.
    private let onLogout: (() -> Void)?
    /// Builds the edit form (for the viewer's own profile); the closure it
    /// receives is invoked after a successful save. Nil for other users.
    /// Handed the profile this screen holds, so the editor opens on it
    /// instead of fetching it again (charter P7).
    private let makeEditViewController: ((UserProfile?, @escaping () -> Void) -> UIViewController)?
    /// The origin said this profile is the viewer's own (`presumesOtherProfile`).
    private let identityStubIsSelf: Bool
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

    /// Retained for the share sheet, which builds its own QR card (and a
    /// throwaway one to rasterize) and needs the same avatar cache.
    private let imagePipeline: ImagePipeline
    /// The player pool, kept for the media gallery "View all" pushes (#631).
    private let videoPlayback: VideoPlaybackController?
    /// That gallery while it is up, so the pages landing reach it.
    private weak var mediaGallery: ProfileMediaGalleryViewController?
    /// Supplies the share sheet's quick-send row; nil hides it.
    private let shareTargeting: (any ProfileShareTargeting)?
    /// Internal (not private) only for the +QA hooks.
    let headerView: ProfileHeaderView
    /// Internal (not private) only for the +QA hooks.
    let galleryPager: ProfileGalleryPagerView
    /// Flies a tapped post into the unified feed. Injected rather than built
    /// here: the card and the transition belong to the feed feature, and this
    /// screen only describes where the post is (see `SnapFeedHeroOrigin`).
    /// Nil leaves every tap on the plain route, which still opens the feed.
    var feedHero: (([PostID], UIViewController, SnapFeedHeroOrigin) -> Void)?
    /// Builds the bar's identity pill — the post page's (#1451). Nil: no
    /// identity in the bar.
    var makePersonBarItem: (@MainActor () -> any PersonBarItem)?
    /// The gallery cards' stakes — see `PostCardStaking`.
    var staking: PostCardStaking? {
        didSet { galleryPager.staking = staking }
    }
    /// Which pages this profile has. The viewer's own carries Saved and Liked;
    /// everyone else's does not, because neither pile is anybody else's to see.
    /// The tabs on show: Posts, and each other source once it has
    /// something in it (#742). One tab is no selector at all.
    private var tabs: [ProfileTab]
    /// Every tab this profile can have.
    private let allTabs: [ProfileTab]
    /// The strip's home when the tab bar is under this screen. Nil on a pushed
    /// profile, where the bottom toolbar carries it instead.
    ///
    /// ⚠️ INSTALLED ON APPEAR, REMOVED ON DISAPPEAR. `bottomAccessory` belongs
    /// to the tab bar controller with no per-tab scope, so a band left up
    /// floats over whatever is pushed on top and over the next tab.
    /// Internal, not private, so the tests can assert what is IN the band —
    /// the arrangement moved out of `toolbarItems`, which a test could read,
    /// into a content view UIKit owns.
    ///
    /// THE TAB ROOT ONLY (#728): a pushed profile hosts the strip as a
    /// bottom-leading toolbar item instead (`selectorItem`).
    var selectorAccessory: SelectorAccessory? { selector.accessory }
    /// The strip's toolbar item, on a pushed profile (#728) — the search
    /// results' too (#881). Internal for tests.
    var selectorItem: UIBarButtonItem? { selector.item }
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
    /// The mute bell, on someone else's profile (#689): the scoped Mute menu
    /// that used to sit in the see-more menu. `bell`, or `bell.slash` once
    /// anything is muted. Kept: the trailing run is compared by reference
    /// (the bar's identical-group guard), so a fresh item is a rebuild — made
    /// when its glyph changes (#1679, R3: under the same identifier, the bar
    /// morphs one into the other), or when the viewer's own change is
    /// revealed under its toast (#1447).
    private lazy var muteBellItem = makeMuteBellItem()
    /// Whether the bell on the bar shows `bell.slash`.
    private var muteBellShowsMuted = false
    /// While the viewer's own mute change is on its way (#1447), the scopes
    /// the bell still shows: its toast reveals the new look; a refusal or an
    /// Undo, back to these, releases it as it is.
    private var bellHeldAt: MuteScopes?
    /// Keeps the bell and the shell's balance two bubbles: iOS 26 groups
    /// adjacent bar items into one platter (the feed's note on
    /// `setEngagedChrome`). Kept for the same by-reference reason.
    private let muteBellSpacer = UIBarButtonItem.fixedSpace(Spacing.sm)
    /// An item the SHELL owns at the head of the leading group — the
    /// notifications bell, on the tab root only (a pushed profile leads with
    /// its back button). Kept as state for the same reason as the trailing
    /// one: the leading run is rewritten in `applyNavigationState`.
    private var leadingAccessoryItem: UIBarButtonItem?
    /// An item the SHELL owns, standing inboard of this screen's own — the
    /// viewer's point balance today, the same badge the Explore header and the
    /// post screen wear.
    ///
    /// Injected rather than built here, and that is the design: three screens
    /// show one number, so one object owns the wallet, the claim countdown and
    /// the sheet, and each screen promises only to keep the item in its
    /// trailing run. Kept as state because that run is REBUILT — see
    /// `applyNavigationState`.
    private var trailingAccessoryItem: UIBarButtonItem?
    /// Whether the header's action tray has scrolled under the bar: the bar
    /// then carries the profile's identity pill, outboard of the balance
    /// (#1451). Never on the viewer's own profile.
    private(set) var isTrayScrolledAway = false
    /// The profile's identity: the post page's pill (#1451, replacing #1224's
    /// Follow item and #1277's badge-less pill), with the relation as the
    /// badge on its face — "+" follows, as the tray's Follow does. A tap
    /// elsewhere on it brings the page back to its top, where the tray is.
    private lazy var barIdentityPill: (any PersonBarItem)? = {
        guard let pill = makePersonBarItem?() else { return nil }
        pill.setOverMedia(false)
        pill.view.accessibilityHint = "Scrolls back to the top of the profile."
        pill.onPersonTapped = { [weak self] _ in self?.galleryPager.scrollActivePageToHeaderTop() }
        pill.onFollowTapped = { [weak self] _ in self?.headerView.onFollowTapped?() }
        return pill
    }()
    private lazy var barIdentityItem: UIBarButtonItem? = barIdentityPill.map {
        BarItems.container(id: "profile.identity-pill", view: $0.view)
    }
    private let relationshipSpacer = UIBarButtonItem.fixedSpace(Spacing.sm)
    /// Keeps History's day in its own bubble, inboard of the trailing group.
    private let sectionSpacer = UIBarButtonItem.fixedSpace(Spacing.sm)
    /// The identity pill as the LEADING group shows it (#1590), nil while
    /// the tray is on screen.
    private var shownBarPill: UIBarButtonItem?
    /// The relationship capsule: Follow / Following.
    ///
    /// **A stock titled item — deliberately not a custom-view item,
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

    /// The loaded profile's @handle — the screen title once known. Stashed so
    /// `viewWillAppear` can bind the bar from current state before the push
    /// animation starts, whenever the data beat the transition.
    private var currentHandle: String?

    /// Internal (not private) only for the +QA hooks.
    private(set) var followButtonState: ProfileViewModel.FollowButton = .hidden

    /// The phase last rendered.
    private var renderedPhase: ProfileViewModel.Phase = .loading
    /// The gallery as last rendered.
    private var lastGallerySnapshot: ProfileViewModel.GallerySnapshot?
    #if DEBUG
    private var hasLoggedFirstFrame = false
    fileprivate var lastTracedReadiness = ""
    fileprivate let debugBornAt = CACurrentMediaTime()
    #endif

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

    init(
        viewModel: ProfileViewModel,
        imagePipeline: ImagePipeline,
        videoPlayback: VideoPlaybackController? = nil,
        makeGridPage: @escaping ProfileGridPageFactory,
        shareTargeting: (any ProfileShareTargeting)? = nil,
        onLogout: (() -> Void)?,
        makeEditViewController: ((UserProfile?, @escaping () -> Void) -> UIViewController)? = nil,
        makeSettingsViewController: (() -> UIViewController)? = nil,
        switcherFactory: ProfileSwitcherMenuFactory? = nil,
        makeRelationshipsViewController: (
            (ProfileRelationshipsViewModel.Subject, RelationshipDirection) -> UIViewController
        )? = nil,
        identityStub: ProfileIdentityStub? = nil,
        trayPlacement: ProfileTrayPlacement = .navigationToolbar
    ) {
        self.trayPlacement = trayPlacement
        self.makeGridPage = makeGridPage
        self.identityStubIsSelf = identityStub?.isSelf == true
        self.viewModel = viewModel
        self.onLogout = onLogout
        self.makeEditViewController = makeEditViewController
        self.makeSettingsViewController = makeSettingsViewController
        self.switcherFactory = switcherFactory
        self.makeRelationshipsViewController = makeRelationshipsViewController
        self.imagePipeline = imagePipeline
        self.videoPlayback = videoPlayback
        self.shareTargeting = shareTargeting
        let header = ProfileHeaderView(imagePipeline: imagePipeline)
        header.bannerVideoPool = videoPlayback
        headerView = header
        // Every profile can carry Saved and Liked (#411, #837): someone
        // else's only when its owner shows them — the server answers empty
        // otherwise, and an empty source is no tab (#742).
        let allTabs = ProfileTab.ownTabs
        self.allTabs = allTabs
        // Posts alone until the other sources answer (#742): a source shows
        // up only with something in it.
        let shown = allTabs.filter { $0 == .format(.activity) }
        self.tabs = shown
        let savesPosts = viewModel.bookmarks != nil
        let pager = ProfileGalleryPagerView(tabs: allTabs) { style in makeGridPage(style, savesPosts) }
        pager.setVisibleTabs(shown)
        pager.presenceScreen = { [weak viewModel] in viewModel?.presenceScreen }
        galleryPager = pager
        // The gallery's format selector — the SAME `PagedTabBar` For You and
        // Messages wear, built `.navigationTitle` and told to FILL — at the
        // foot of the screen in the home `trayPlacement` says.
        super.init(
            header: header, pager: pager,
            selectorBar: PagedTabBar(titles: shown.map(\.title), style: .navigationTitle),
            selectorPlacement: trayPlacement == .aboveBottomSafeArea ? .accessory : .toolbar
        )

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
        // A stub with no handle (a thread, a notification row, #1858) titles
        // the profile with the name until the profile brings the handle.
        if let identityStub {
            currentHandle = identityStub.handle.map { "@" + $0 }
                ?? (identityStub.displayName.isEmpty ? nil : identityStub.displayName)
        }
        // Frame-1 state for the relationship capsule. "Edit Profile" on
        // surfaces that are the viewer's own by construction; the origin's
        // answer when it had one; otherwise `.hidden` — a blank placeholder
        // capsule, NOT "Follow". The prior used to be "Follow" ("most viewed
        // profiles aren't followed"), and every followed author's profile
        // then arrived wearing a blue call to action that turned grey a
        // moment later. The push never waits for the answer (#778); the
        // placeholder holds the slot until the read lands.
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
            followButtonState = .hidden
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidLoad() {
        // The hero page's layout, bar dress and travel (#1655).
        super.viewDidLoad()
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
        heroPager.onPinnedSectionChanged = { [weak self] section in self?.applyPinnedSection(section) }
        galleryPager.onNearEnd = { [weak self] in self?.viewModel.loadMoreGallery() }
        galleryPager.onRetry = { [weak self] in self?.viewModel.retryGallery() }

        viewModel.onPhaseChange = { [weak self] phase in
            HeroScreenCost.measure("landing.phase") { self?.render(phase) }
        }
        viewModel.onFollowButtonChange = { [weak self] state in
            guard let self else { return }
            HeroScreenCost.measure("landing.relationship") {
                self.followButtonState = state
                self.headerView.configureAction(state)
                // Whose posts these are just changed: on the viewer's own
                // profile the rows gain Edit and Delete, drawn now rather
                // than once each row is configured again.
                self.galleryPager.refreshAuthorMenus()
                // A bell that has to GO (a handle that turned out to be the
                // viewer, #800) leaves at rest and unanimated: removing a bar
                // item mid-push pops it on device (#756).
                if self.isShowingMuteBell, !self.showsMuteBell {
                    self.applyNavigationStateAtRest()
                } else {
                    // The relationship usually resolves while the push/present
                    // is still animating; bind the bar inside the transition so
                    // the toolbar composes during the animation, not after it.
                    self.alongsideTransition { $0.applyNavigationState(animated: $1) }
                }
                self.noteLandingMilestone()
            }
        }
        viewModel.onRelationshipSettled = { [weak self] in
            guard let self else { return }
            // The button moves before the read counts as settled, so the
            // bar it recomposed could still presume someone else: a bell the
            // answer rules out (the viewer's own handle, #800) goes now.
            if self.isShowingMuteBell, !self.showsMuteBell { self.applyNavigationStateAtRest() }
            self.noteLandingMilestone()
        }
        headerView.onPicturesSettled = { [weak self] in self?.noteLandingMilestone() }
        viewModel.onMapPinButtonChange = { [weak self] _ in
            HeroScreenCost.measure("landing.mapPin") {
                // The rails' rows keep the menu open (`.keepsMenuPresented`):
                // their checkmarks follow in place.
                self?.refreshVisibleMapRows()
                self?.noteLandingMilestone()
            }
        }
        viewModel.onMuteScopesChange = { [weak self] scopes in
            guard let self else { return }
            // Back to what the held bell shows (refused, undone): nothing to
            // reveal any more.
            if bellHeldAt == scopes { bellHeldAt = nil }
            refreshMuteBell()
        }
        headerView.onFollowTapped = { [weak self] in
            guard let self else { return }
            MemberGates.perform(.follow(handle: viewModel.profile?.handle), from: self) { [weak self] in
                // On at the optimistic flip; off is silent (#1886).
                if self?.viewModel.toggleFollow() == true { Haptics.play(.toggleOn) }
            }
        }
        headerView.onMessageTapped = { [weak self] in
            guard let self else { return }
            MemberGates.perform(.message(handle: viewModel.profile?.handle), from: self) { [weak self] in
                self?.viewModel.messageTapped()
            }
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
        // Deleting a post, muting, restricting: done at once on screen, with
        // Undo in the toast; sent when its countdown runs out (#957).
        viewModel.onUndoable = { [weak self] action in
            guard let self else { return }
            Feedback.undoable(
                action.message, symbol: action.symbol, from: self,
                revealing: { [weak self] in self?.revealMuteBell() },
                commit: action.commit, undo: action.undo
            )
        }
        viewModel.onDismissRequested = { [weak self] in
            self?.leaveAfterBlock()
        }
        viewModel.onLoadSettled = { [weak self] in
            HeroScreenCost.measure("landing.settled") {
                self?.isSwitchingProfile = false
                // A refresh that brought nothing new publishes no phase, so
                // the spinner stops here — where every load ends, however it
                // ended.
                self?.pullIndicator.endRefreshing()
            }
        }
        // A gallery that landed before this screen bound: its tabs now.
        if let landed = viewModel.publishedGallery {
            lastGallerySnapshot = landed
            showTabs(for: landed)
        }
        viewModel.onGalleryChange = { [weak self] snapshot in
            self?.lastGallerySnapshot = snapshot
            self?.showTabs(for: snapshot)
            HeroScreenCost.measure("landing.gallery") { self?.galleryPager.render(snapshot) }
            // The media gallery "View all" pushed, if it is up, grows with
            // the pages as they land (#631).
            self?.mediaGallery?.render(snapshot.media)
            self?.noteLandingMilestone()
            #if DEBUG
            self?.auditPostMenu(snapshot)
            #endif
        }
        galleryPager.onItemTapped = { [weak self] post, stream in
            self?.openGalleryPost(post, stream: stream, showingComments: false)
        }
        // A card's comment chip: the same open, arriving with the thread up.
        galleryPager.onItemCommentsTapped = { [weak self] post, stream in
            self?.openGalleryPost(post, stream: stream, showingComments: true)
        }
        galleryPager.onAuthorTapped = { [weak self] post in
            self?.viewModel.galleryAuthorTapped(post)
        }
        galleryPager.onViewAllTapped = { [weak self] in self?.pushMediaGallery() }
        galleryPager.authorMenuActions = { [weak self] context, tab in
            guard let self else { return [] }
            var actions = galleryMenuActions(for: context)
            // History's own row (#1344): out of the history, not the post.
            if tab == .history {
                let id = context.post.id
                actions.insert(.removeFromHistory { [weak self] in self?.viewModel.removeFromHistory(id) }, at: 0)
            }
            return actions
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
        render(.loading)
        viewModel.viewDidLoad()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        // The profile TAB's root: the notifications drawer is "page −1", pulled
        // past the first tab with the tabs' own gesture, from the very edge
        // (#1739). A pushed profile keeps its first-tab dismissal and its back swipe.
        let isTabRoot = navigationController?.viewControllers.first === self
        galleryPager.leadingPullTarget = isTabRoot ? DrawerPull.shared : nil
        galleryPager.reservesLeadingEdge = !isTabRoot
        Task { [weak self] in await self?.viewModel.refreshShareToken() }
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
            // Minimizes with the scroll on the tab root only — see
            // `HeroPageSelector.install`.
            selector.install(on: self, alongside: transitionCoordinator)
        }
        // A pushed profile's strip rides the stack's toolbar (#728).
        selector.showToolbar(for: self, animated: animated)
        // The accessory's collapse rides the active page: name it again on
        // every appearance, as the inbox's pager does (#1191).
        galleryPager.republishActiveScrollView()

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
        //
        // ⚠️ …and a close of the snap feed that no finger drives cannot un-hide
        // it from inside itself: the feed's owner shows it before that pop
        // (`onWillCloseFeed`), and the policy answers "after the landing" only
        // as the backstop. It is never held back by an alpha — native chrome
        // is UIKit's (see `TabBarRevealPolicy`). Video 3 of 2026-09-28 (Activity
        // → media post → close) filmed the old rule's cost: the bar, held for
        // the landing, arrived late.
        if navigationController?.viewControllers.first === self,
           tabBarController?.isTabBarHidden == true {
            // This screen owns no flight object — a post opened from here is
            // presented by the feed feature. A close of that feed is recognised
            // from the transition itself.
            revealBottomChromeWhenAllowed(animated: animated) { [weak self] animated in
                self?.revealDock(animated: animated)
            }
        }
        // Re-bind the bar synchronously BEFORE the transition animates: any
        // state that resolved since viewDidLoad (fast mock loads, cached
        // profiles, returning from a pushed child) is fully populated here,
        // so the title and Follow item ride the push natively instead of
        // popping in after it.
        applyNavigationState()
        #if DEBUG
        // `-profile-first-frame-log`: what the slide's first frame carries —
        // the state a push held for it (charter P12a) should have settled.
        if !hasLoggedFirstFrame, ProcessInfo.processInfo.arguments.contains("-profile-first-frame-log") {
            hasLoggedFirstFrame = true
            print("[profile-first-frame] settled=\(isSettled) "
                  + "redacted=\(debugIsHeaderRedacted) follow=\(debugFollowTitle ?? "placeholder") "
                  + "avatar=\(debugHasAvatarPicture ? "picture" : "initials") "
                  + "banner=\(headerView.bannerFormat) gallerySettled=\(isGallerySettled)")
        }
        #endif
        // ⚠️ On every appearance, not once. The saved pile is mutable from
        // outside this screen — the feed's bookmark button writes to the same
        // store — so a Saved tab bound at load would be stale the first time
        // the viewer saved something and came back to look at it.
        viewModel.loadSavedPosts()
        // What the viewer viewed in the feed they just closed (#1344).
        viewModel.loadHistory()
    }

    /// Puts the dock back, idempotently — through UIKit, never an alpha.
    ///
    /// The guard is what makes it safe to call from more than one place: the
    /// feed's own close can show it before or after this, and two animated
    /// reveals of an already-visible bar is a flicker.
    private func revealDock(animated: Bool) {
        guard let tabBarController, tabBarController.isTabBarHidden else { return }
        if animated {
            tabBarController.showTabBarNatively()
        } else {
            tabBarController.setTabBarHidden(false, animated: false)
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        // The band comes down; the toolbar is the stack's, put away unless the
        // screen taking over brings items of its own (the relations screen,
        // the feed).
        selector.hide(leaving: self, animated: animated, alongside: transitionCoordinator)
        // Stops as this screen is covered — including by the post it just
        // opened, whose own player is what should be heard.
        galleryPager.setAutoplayActive(false)
        // Not the banner (#1399): the hero page plays it on while the screen
        // leaves.
    }

    /// The post has finished covering this screen, so the tapped tile can be
    /// brought clear of the chrome without anyone seeing it move.
    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        // Not `viewWillDisappear`: that fires as the transition begins, while
        // the grid is still visible behind an expanding hero card.
        galleryPager.applyPendingReveal()
        // What the cards staked while the screen was up is final now.
        staking?.endSession()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // A tab root always shows the bar (#769).
        ensureAppTabBarAsTabRoot()
        // The BACKSTOP, on UIKit's own animation like every other install
        // (native chrome is UIKit's — see `TabBarRevealPolicy`). A tab switch
        // and a committed close install from `viewWillAppear` and find nothing
        // to do here.
        selector.install(on: self, alongside: transitionCoordinator)
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
            // ⚠️ AND THE FULL-SURFACE ONE (#1324): it is this screen's back
            // swipe now, in place of the slide the pager used to wait for. Left
            // simultaneous, a drag on the first tab paged the gallery instead of
            // popping (traced: the swipe began, the pager took the drag). The
            // swipe declines on the later tabs (`allowsContentPop`), and the
            // pager pages there.
            if #available(iOS 26.0, *), let content = navigationController?.interactiveContentPopGestureRecognizer {
                galleryPager.horizontalPan.require(toFail: content)
            }
        }
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
            // The 1.5s is kept as a floor (the settle beat the audit was
            // calibrated on), but the print now WAITS FOR THE PROFILE: on a slow
            // run the fixed delay dumped the redacted skeleton header and the
            // spacing audit measured bones, reading like a real layout.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                QAWait.until("profile-layout-audit", { [weak self] in
                    self?.viewModel.profile != nil
                }) { [weak self] in
                    guard let self else { return }
                    // The content render lands in THIS turn's layout pass at
                    // the earliest; flush it so the frames are the loaded ones.
                    self.view.layoutIfNeeded()
                    let description = self.headerView
                        .perform(Selector(("recursiveDescription")))?
                        .takeUnretainedValue()
                    print("PROFILE-LAYOUT-AUDIT\n\(description.map(String.init(describing:)) ?? "unavailable")")
                }
            }
        }
        // Dev convenience: `-profile-ink-audit` prints the WCAG contrast of
        // the name and the handle against the pixels actually rendered behind
        // them (see `ProfileHeaderView.debugIdentityContrast`) — once the
        // profile AND its banner picture are in, since the picture decides
        // both the shape and what the type stands on.
        if ProcessInfo.processInfo.arguments.contains("-profile-ink-audit") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                QAWait.until("profile-ink-audit", { [weak self] in
                    guard let self, self.viewModel.profile != nil else { return false }
                    return self.headerView.bannerFormat == .none || self.headerView.debugBannerHasPicture
                }) { [weak self] in
                    guard let self else { return }
                    // Past the banner's 0.25s dissolve.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                        guard let self else { return }
                        self.view.layoutIfNeeded()
                        let style = self.traitCollection.userInterfaceStyle == .dark ? "dark" : "light"
                        guard let contrast = self.headerView.debugIdentityContrast() else {
                            print("PROFILE-INK-AUDIT unavailable")
                            return
                        }
                        print(
                            "PROFILE-INK-AUDIT format=\(self.headerView.bannerFormat) style=\(style) "
                                + "tones=\(self.headerView.debugInkTones) "
                                + "name=[\(contrast.name)] handle=[\(contrast.handle)] "
                                + String(format: "blur-bake=%.1fms %dKB", self.headerView.debugBlurBakeMilliseconds,
                                         self.headerView.debugBlurBakeBytes / 1024)
                                + " " + (self.headerView.debugBodyContrast() ?? [])
                                    .map { "\($0.0)=[\($0.1)]" }.joined(separator: " ")
                        )
                    }
                }
            }
        }
        // Dev convenience: `-profile-menu-audit` prints the "..." menu the
        // current state resolves to, and fires the copy action so the toast is
        // screenshottable. The menu is the one thing on this screen no launch
        // argument can otherwise reach — it opens on a tap, and the sim has no
        // touch injection.
        if ProcessInfo.processInfo.arguments.contains("-profile-menu-audit") {
            // Waits for the RELATIONSHIP READ, not just the clock: the menu's
            // moderation group and its Block/Unblock title are both decided by
            // it, and with `-profile-relationship-delay` (3s) the fixed 1.5s
            // printed `canModerate=false isBlocked=false` — the pre-read menu,
            // reported as the answer. The read is in when this is someone
            // else's profile we can moderate, or the subject is known to be the
            // viewer (own profile, or a routed one the read said is self).
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                QAWait.until("profile-menu-audit", { [weak self] in
                    guard let self else { return false }
                    return self.viewModel.canModerate
                        || self.viewModel.relationshipsSubject?.isSelf == true
                }) { [weak self] in
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
            // Each step waits for the state the next one reads. The push needs
            // a loaded profile (the editor is built from it) and a stack at
            // rest with this screen on top; the Privacy row needs the editor
            // to have LANDED. The fixed 1s between them used to reach for
            // `topViewController as? EditProfileViewController` while the
            // push was still in flight — or had never started — and no-op.
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                guard let self else { return }
                guard makeEditViewController != nil else {
                    QAWait.fail("profile-edit-privacy", "this profile has no editor (not the viewer's own)")
                    return
                }
                QAWait.until("profile-edit-privacy push", { [weak self] in
                    guard let self, let navigation = self.navigationController else { return false }
                    return self.viewModel.profile != nil
                        && navigation.topViewController === self
                        && navigation.transitionCoordinator == nil
                }) { [weak self] in
                    guard let self else { return }
                    self.pushEditProfile()
                    QAWait.until("profile-edit-privacy open", { [weak self] in
                        guard let navigation = self?.navigationController else { return false }
                        return navigation.topViewController is EditProfileViewController
                            && navigation.transitionCoordinator == nil
                    }) { [weak self] in
                        self?.qaOpenPrivacy()
                    }
                }
            }
        }
        if arguments.contains("-profile-follow-tap") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                self?.qaTapFollowItem()
            }
        }
        // Dev convenience: `-open-settings [section]` pushes Settings once this
        // screen is at rest on top, then the named section (a
        // `SettingsSection` raw value: account, security, privacy, legal…).
        // The gear is a bar item, which takes no simulated touch.
        if let flag = arguments.firstIndex(of: "-open-settings") {
            let next = arguments.index(after: flag)
            let sectionName = next < arguments.endIndex && !arguments[next].hasPrefix("-") ? arguments[next] : nil
            QAWait.until("open-settings push", { [weak self] in
                guard let self, let navigation = self.navigationController else { return false }
                return navigation.topViewController === self && navigation.transitionCoordinator == nil
            }) { [weak self] in
                guard let self else { return }
                guard self.makeSettingsViewController != nil else {
                    QAWait.fail("open-settings", "this profile has no settings (not the viewer's own)")
                    return
                }
                self.pushSettings()
                guard let sectionName else { return }
                guard let section = SettingsSection(rawValue: sectionName) else {
                    QAWait.fail("open-settings", "unknown section \(sectionName)")
                    return
                }
                QAWait.until("open-settings section", { [weak self] in
                    guard let navigation = self?.navigationController else { return false }
                    return navigation.topViewController is SettingsViewController
                        && navigation.transitionCoordinator == nil
                }) { [weak self] in
                    (self?.navigationController?.topViewController as? SettingsViewController)?.open(section)
                }
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
        // `-profile-tab <posts|saved|liked>` selects a tab on the viewer's own
        // profile, `<posts|reposts|tagged>` on someone else's (#696).
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
        // `-profile-view-all [seconds]`: pushes the media gallery a chunk's
        // "View all" opens (#631), once the posts have had time to land.
        if let position = arguments.firstIndex(of: "-profile-view-all") {
            let delay = position + 1 < arguments.count ? Double(arguments[position + 1]) ?? 2 : 2
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.pushMediaGallery()
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
                let probeItem = BarItems.container(id: "profile.debug.dock-probe", view: swatch)
                var leading = navigationItem.leftBarButtonItems ?? []
                leading.append(probeItem)
                navigationItem.leftBarButtonItems = leading
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    print("[dock] PROBE plainItemHosted=\(swatch.window != nil) "
                        + "frame=\(swatch.frame) leftCount=\(self.navigationItem.leftBarButtonItems?.count ?? -1)")
                }
            }
        }
        // `-profile-scroll <points>` scrolls the active page before anything
        // else, so a tile can be driven while it is tucked UNDER the header —
        // at rest nothing is, since the content starts below it, and that is
        // the only state the header-alignment bug appears in.
        if let position = arguments.firstIndex(of: "-profile-scroll"),
           position + 1 < arguments.count, let points = Double(arguments[position + 1]) {
            // Polls: a fixed delay clamps to the top while the page is still
            // loading and the run then tests a tile at rest, which is the
            // one state the alignment bug cannot appear in.
            //
            // Through `QAWait` now, so running out of attempts PRINTS — it
            // used to fall off the end of the loop silently. What counts as
            // done is `debugSetVerticalOffset`'s to say: the requested offset,
            // or the end of a page whose content has actually loaded (see there
            // for why a loading page's clamp used to pass on the first try).
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                QAWait.until("profile-scroll \(points)", timeout: 15, interval: 0.25, { [weak self] in
                    self?.galleryPager.debugSetVerticalOffset(CGFloat(points)) ?? false
                }) { [weak self] in
                    guard let self else { return }
                    print("[qa] profile-scroll settled requested=\(points) "
                        + "offset=\(galleryPager.verticalOffset)")
                }
            }
        }
        // `-profile-scroll-sweep`: scrolls the page from the top to 240pt and
        // back, frame by frame, 3s each way (after 2.5s) — the header's fade
        // and parallax filmed without touch injection — and says what each
        // frame cost (`HeroScrollFrameProbe`: `HERO-SCROLL profile …` on
        // standard error).
        if arguments.contains("-profile-scroll-sweep") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
                guard let self else { return }
                debugSweepStep(began: CACurrentMediaTime(), probe: HeroScrollFrameProbe(name: "profile", root: headerView))
            }
        }
        // `-profile-stretch-sweep`: once the profile and its picture are in,
        // pulls the page down past its top — the banner stretching — to
        // `HeroStretchSweep.depth`, holds, lets go through the refresh a
        // finger's release would start, and settles at rest while it lands
        // (`HERO-SCROLL profile-stretch/<phase> …` on standard error, see
        // `HeroScrollFrameProbe`).
        if arguments.contains("-profile-stretch-sweep") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                QAWait.until("-profile-stretch-sweep", { [weak self] in
                    guard let self else { return false }
                    return viewModel.profile != nil && headerView.debugBannerHasPicture
                }) { [weak self] in
                    // The bake lands a beat after the picture.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                        guard let self else { return }
                        debugStretchStep(
                            began: CACurrentMediaTime(),
                            probe: HeroScrollFrameProbe(name: "profile-stretch", root: headerView), phase: nil
                        )
                    }
                }
            }
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
                // ⚠️ THE SUCCESS EXIT THIS LOOP NEVER HAD. It re-forced the
                // offset for the full 40s and then printed GAVE UP on every run,
                // docked or not — so the promised SETTLED line did not exist and
                // the only verdict it could give was a failure. Docked is the
                // header's own definition: the active page has travelled at
                // least `headerTravel`, the line `applyHeaderOffset` stops the
                // header at and the identity fade finishes on. A zero travel
                // means the header has not laid out, which is not a dock.
                let dockLine = headerTravel
                let offset = galleryPager.verticalOffset
                if dockLine > 0, offset >= dockLine - 0.5 {
                    print("[dock] SETTLED docked=true attempts=\(attempts) "
                        + "offset=\(offset) dockLine=\(dockLine) "
                        + "offsets=\(galleryPager.debugVerticalOffsets)")
                    return
                }
                if attempts < 160 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: attempt)
                } else {
                    print("[dock] GAVE UP docked=false attempts=\(attempts) "
                        + "offsets=\(galleryPager.debugVerticalOffsets) "
                        + "hasGallery=\(viewModel.hasGallery)")
                    // The shared GAVE UP line too, so one grep covers every hook.
                    QAWait.fail("profile-dock", "offset=\(offset) dockLine=\(dockLine)")
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
            // Both steps are gated on state now. `presentShareSheet` returns
            // without a word until `shareCard` exists (a loaded profile), and a
            // stack mid-transition refuses the presentation — so the fixed 2s
            // opened nothing on a slow run, and the chained step then optional-
            // chained every call onto a nil sheet: a whole scripted sequence
            // that exercised nothing and printed nothing.
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                QAWait.until("profile-share-demo present", { [weak self] in
                    guard let self, let navigation = self.navigationController else { return false }
                    return self.viewModel.shareCard != nil
                        && navigation.topViewController === self
                        && navigation.transitionCoordinator == nil
                        && self.presentedViewController == nil
                }) { [weak self] in
                    self?.presentShareSheet()
                    let chainedActions = [
                        "activity", "send", "search", "search-empty", "search-cancel",
                        "search-send", "search-scroll", "search-lower"
                    ]
                    guard chainedActions.contains(chained ?? "") else { return }
                    // Waits for the sheet to have FINISHED presenting (the 2s
                    // stood in for that) rather than for the clock.
                    QAWait.until("profile-share-demo \(chained ?? "")", { [weak self] in
                        guard let sheet = self?.presentedViewController as? ProfileShareViewController
                        else { return false }
                        return !sheet.isBeingPresented && sheet.transitionCoordinator == nil
                    }) { [weak self] in
                        self?.qaRunShareChain(chained)
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
            // `block` returns without a word unless the profile has loaded AND
            // the relationship read has made it moderatable — so the fixed 2s
            // blocked nothing on a slow run and the run still looked done.
            // Waits for the read to settle either way (moderatable, or known to
            // be the viewer), then says why when it cannot block.
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                QAWait.until("profile-block-demo", { [weak self] in
                    guard let self else { return false }
                    return self.viewModel.canModerate
                        || self.viewModel.relationshipsSubject?.isSelf == true
                }) { [weak self] in
                    guard let self else { return }
                    guard viewModel.canModerate else {
                        QAWait.fail("profile-block-demo", "this is the viewer's own profile")
                        return
                    }
                    guard !viewModel.isBlocked else {
                        QAWait.fail("profile-block-demo", "the profile is already blocked")
                        return
                    }
                    viewModel.block(scope)
                }
            }
        }
        #endif
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

    /// Ticks the rail rows of the open see-more menu to the current state:
    /// a row keeps the menu open, and its mark must follow
    /// (`ProfileMenuBuilder.retickingMapRows`).
    private func refreshVisibleMapRows() {
        let current = viewModel.mapPinButton.categories
        headerView.updateVisibleMoreMenu { menu in
            ProfileMenuBuilder.retickingMapRows(in: menu, to: current)
        }
    }

    /// The map rails' rows for the current state (`ProfileMenuBuilder`).
    private func mapFavoriteMenuActions() -> [UIAction] {
        ProfileMenuBuilder.mapFavoriteMenuActions(viewModel.mapPinButton) { [weak self] category in
            self?.viewModel.toggleMapCategory(category)
        }
    }

    private func pushEditProfile() {
        guard let makeEditViewController else { return }
        // Pushed onto the profile's own stack, not presented: back / edge-swipe
        // returns here. Edits are per-field (each pushes its own screen), so a
        // save refreshes the profile underneath but does NOT pop the editor —
        // the user leaves the list themselves when done.
        let editViewController = makeEditViewController(viewModel.profile) { [weak self] in
            self?.viewModel.refresh()
        }
        navigationController?.pushViewController(editViewController, animated: true)
    }

    // MARK: - Mute bell

    /// Whether the bell stands in the bar: a profile the viewer FOLLOWS, in
    /// a composition that can mute, for a member. The same rule the see-more
    /// menu's Mute submenu had (#689): a guest has no account to mute from.
    ///
    /// ⚠️ NO BELL UNTIL THE READ SAYS FOLLOWING (the owner, 2026-10-18,
    /// #1398). It used to be presumed from frame 0 on someone else's profile
    /// (#778) and taken away once the read said "not followed" — so every
    /// profile the viewer does not follow showed a bell for the whole push,
    /// then lost it. There is nothing of theirs to mute until they are
    /// followed (2026-10-15), and an unknown relationship is not "followed".
    /// The bell ARRIVES once the push has settled, animated
    /// (`updateActionBarItem`): an item added mid-push lands unanimated at
    /// its end on device (#756).
    private var showsMuteBell: Bool {
        guard !viewModel.namesNoOne, followButtonState == .following else { return false }
        return viewModel.canMute && MemberGates.gate(from: self)?.isMember != false
    }

    /// Whether the bell can be used yet: a handle or link route has no one to
    /// mute until the relationship read says the lookup found someone else.
    private var isMuteBellEnabled: Bool {
        !viewModel.wasOpenedByReference || viewModel.canModerate
    }

    /// The keys the router's repeat filter asks about (#800).
    var profileRouteKeys: Set<ProfileRouteKey> { viewModel.profileRouteKeys }

    /// A profile reached by id that is not the viewer's own, as far as frame 0
    /// can tell: no self stub, no Edit wiring.
    private var presumesOtherProfile: Bool {
        !viewModel.isOwnProfile && !identityStubIsSelf && makeEditViewController == nil
    }

    /// Resolved when it opens, so the checkmarks are the current scopes.
    private func makeMuteMenu() -> UIMenu {
        UIMenu(children: [UIDeferredMenuElement.uncached { [weak self] completion in
            completion(self?.muteMenuElements() ?? [])
        }])
    }

    /// The scoped Mute menu for the current scopes (`ProfileMenuBuilder`).
    private func muteMenuElements() -> [UIMenuElement] {
        ProfileMenuBuilder.muteMenuElements(viewModel.muteScopes) { [weak self] scope in
            self?.toggleMuteHoldingBell(scope)
        }
    }

    /// The menu's mute: the bell keeps its look until the change's toast
    /// takes its place, and comes back changed when it leaves (#1447) —
    /// whether the toast comes on the tap (Undo) or once the server answered.
    private func toggleMuteHoldingBell(_ scope: MuteScope) {
        let before = viewModel.muteScopes
        bellHeldAt = before
        viewModel.toggleMute(scope)
        // Nothing changed (a change already on its way): nothing held.
        if viewModel.muteScopes == before { bellHeldAt = nil }
    }

    static let muteBellID = "profile.mute-bell"

    private func makeMuteBellItem() -> UIBarButtonItem {
        let item = BarItems.icon(
            id: Self.muteBellID, image: UIImage(systemName: "bell"), label: "Notifications", menu: makeMuteMenu()
        )
        item.tintColor = .label
        return item
    }

    /// The spoken value follows the scopes in place; a new glyph is a new
    /// item under the same identifier, set animated — the bar morphs the
    /// bell (#1679, R3), never an image swapped on the item it shows. Not
    /// while the viewer's own change is held (#1447).
    private func refreshMuteBell() {
        guard bellHeldAt == nil else { return }
        let muted = !viewModel.muteScopes.isEmpty
        guard muted != muteBellShowsMuted, isShowingMuteBell else {
            applyMuteLook(to: muteBellItem)
            return
        }
        // Never mid-push: an item swapped then lands unanimated at its end (#756).
        if transitionCoordinator != nil, let navigationController {
            navigationController.whenAtRest { [weak self] in self?.refreshMuteBell() }
            return
        }
        let item = makeMuteBellItem()
        applyMuteLook(to: item)
        muteBellItem = item
        updateActionBarItem(followButtonState, animated: view.window != nil)
    }

    private func applyMuteLook(to item: UIBarButtonItem) {
        let scopes = viewModel.muteScopes
        item.image = UIImage(systemName: scopes.isEmpty ? "bell" : "bell.slash")
        item.accessibilityValue = scopes.isEmpty ? "Nothing muted" : "Muted: " + scopes.summary
        muteBellShowsMuted = !scopes.isEmpty
    }

    /// The held bell's new look, under its toast (#1447): a FRESH item, so
    /// the one the toast is replacing leaves the bar as it was, and the new
    /// one is among the items that come back.
    private func revealMuteBell() {
        guard bellHeldAt != nil else { return }
        bellHeldAt = nil
        let item = makeMuteBellItem()
        applyMuteLook(to: item)
        muteBellItem = item
        updateActionBarItem(followButtonState, animated: view.window != nil)
    }

    #if DEBUG
    /// Stands in for the scroll: the tray out of sight, or back.
    /// The scroll's own path: the header placed for `travelled`, the tray's
    /// visibility decided from it.
    func debugApplyHeaderOffset(_ travelled: CGFloat) { applyHeaderOffsetNow(travelled) }
    func debugSetTrayScrolledAway(_ away: Bool) {
        isTrayScrolledAway = away
        updateActionBarItem(followButtonState)
    }
    /// The bar's identity pill, if it shows one.
    var debugBarRelationshipItem: UIBarButtonItem? {
        (navigationItem.leftBarButtonItems ?? []).first { $0 === barIdentityItem }
    }
    var debugBarIdentityPill: (any PersonBarItem)? { barIdentityPill }
    /// The bell, if the bar shows it.
    var debugMuteBellItem: UIBarButtonItem? {
        ownTrailingBarItems.first { $0 === muteBellItem }
    }
    /// What picking the bell menu's `scope` does. Tests.
    func debugToggleMute(_ scope: MuteScope) { toggleMuteHoldingBell(scope) }
    func debugMuteMenuElements() -> [UIMenuElement] { muteMenuElements() }
    func debugMoreMenuElements() -> [UIMenuElement] { moreMenuElements() }
    /// The map pin's rows, for `-profile-map-pin-audit` (+QA).
    func debugMapFavoriteMenuActions() -> [UIAction] { mapFavoriteMenuActions() }
    /// A gallery card's "..." rows, for `-post-menu-audit` (+QA).
    func debugGalleryMenuActions(
        for context: PostGridAuthorMenuContext
    ) -> [PostCardMenuAction] {
        galleryMenuActions(for: context)
    }
    #endif

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
        ProfileMenuBuilder.moreMenuElements(
            ProfileMenuBuilder.MoreMenuState(
                canShare: viewModel.shareCard != nil,
                mapPin: viewModel.mapPinButton,
                canModerate: viewModel.canModerate,
                isGuest: MemberGates.gate(from: self)?.isMember == false,
                canRestrict: viewModel.canRestrict,
                isRestricted: viewModel.isRestricted,
                isBlocked: viewModel.isBlocked,
                canClearHistory: viewModel.isOwnProfile && viewModel.hasHistory
            ),
            handlers: ProfileMenuBuilder.MoreMenuHandlers(
                share: { [weak self] in self?.presentShareSheet() },
                copyLink: { [weak self] in self?.copyProfileLink() },
                toggleMapCategory: { [weak self] category in self?.viewModel.toggleMapCategory(category) },
                report: { [weak self] in self?.presentReportReasons() },
                toggleRestrict: { [weak self] in self?.viewModel.toggleRestrict() },
                unblock: { [weak self] in self?.viewModel.unblock() },
                confirmBlock: { [weak self] in self?.confirmBlock() },
                clearHistory: { [weak self] in self?.confirmClearHistory() }
            )
        )
    }

    /// "Clear History" asks once (#1344): the list cannot be brought back.
    private func confirmClearHistory() {
        let alert = UIAlertController(
            title: "Clear History?",
            message: "Posts you watched will no longer appear in History.",
            preferredStyle: .actionSheet
        )
        alert.addAction(UIAlertAction(title: "Clear History", style: .destructive) { [weak self] _ in
            self?.viewModel.clearHistory()
        })
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        present(alert, animated: true)
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
        Feedback.success("Link copied", symbol: "link", from: self)
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
    ///
    /// The picker itself now lives in `PostGrid`, beside the post card's "..."
    /// that raises the same question: two screens asking a viewer to classify
    /// a report must ask it in the same words, and the second copy would have
    /// been written the day the card grew a Report row.
    /// Report only — or, on the viewer's own post, Edit and Delete
    /// (`ProfileMenuBuilder.galleryMenuActions`).
    private func galleryMenuActions(
        for context: PostGridAuthorMenuContext
    ) -> [PostCardMenuAction] {
        ProfileMenuBuilder.galleryMenuActions(
            isViewerPost: viewModel.isViewerPost(by: context.authorID),
            canReport: viewModel.canReportPost(by: context.authorID),
            // At once, with Undo in the toast (#957) — no confirmation sheet.
            onDelete: { [weak self] in self?.viewModel.deletePost(context.post.id) },
            onReport: { [weak self] in self?.presentPostReportReasons(for: context) }
        )
    }

    /// The same question, asked of a post instead of the profile — and asked by
    /// the same picker, anchored on the row's own "..." rather than on the
    /// header's.
    private func presentPostReportReasons(
        for context: PostGridAuthorMenuContext
    ) {
        ReportReasonSheet.present(
            from: self, subject: "this post", sourceView: context.anchor
        ) { [weak self] reason in
            self?.viewModel.reportPost(context.post.id, reason: reason)
        }
    }

    private func presentReportReasons() {
        ReportReasonSheet.present(
            from: self,
            subject: viewModel.handle ?? "this profile",
            sourceView: headerView.moreButtonAnchor
        ) { [weak self] reason in
            self?.viewModel.report(reason)
        }
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
            // Sourced from the navigation controller, not this screen: the
            // block pops this view controller in the same turn, and a toast
            // parented here would leave with it.
            Feedback.success(message, symbol: "hand.raised.fill", from: navigationController ?? self)
        case .unblocked(let handle):
            Feedback.success("Unblocked \(handle)", symbol: "hand.raised.slash.fill", from: self)
        case .muteChanged(let handle, let scopes):
            Feedback.success(
                ProfileViewModel.muteMessage(handle: handle, scopes: scopes),
                symbol: scopes.isEmpty ? "speaker.wave.2.fill" : "speaker.slash.fill",
                from: self,
                revealing: { [weak self] in self?.revealMuteBell() }
            )
        case .restrictChanged(let handle, let restricted):
            Feedback.success(
                restricted ? "Restricted \(handle)" : "Unrestricted \(handle)",
                symbol: restricted ? "person.crop.circle.badge.minus" : "person.crop.circle.badge.checkmark",
                from: self
            )
        case .commitFailed(let message):
            // Already put back on screen (#957): say why it came back.
            Feedback.failure(message, from: self)
        case .reported:
            Feedback.success("Report sent", symbol: "flag.fill", from: self)
        case .followFailed(let message):
            // A toast, not the alert below: the button has already flipped
            // back, so there is nothing to decide — only why it moved (#802).
            Feedback.failure(message, from: self)
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
        // THIS profile, wherever it is now (#1144): the block answered after
        // an `await`, and the viewer may have gone back or pushed on since —
        // a plain pop would have closed that other screen.
        closeScreen()
    }

    // MARK: - Setup

    /// The viewer's own bar items: the gear and the switcher. The bar's
    /// dress — transparent, white ink over the banner — is the hero page's.
    private func configureNavigationBar() {
        // Account actions only exist for the viewer's own profile. (`onLogout`
        // is retained for the Account Settings screen, which will host Log Out.)
        guard onLogout != nil else { return }
        // Settings gear — the viewer's account entry point. A plain trailing
        // item (no leading item, so it never disturbs the edge-swipe pop),
        // tinted `.label` to read as primary dark chrome over the banner.
        let settings = BarItems.icon(id: "profile.settings", image: UIImage(systemName: "gearshape"), label: "Settings") {
            [weak self] in self?.pushSettings()
        }
        settings.tintColor = .label
        settingsItem = settings

        // Profile switcher — the leading item, opposite the gear (see
        // `applyNavigationState` for why the leading slot is free here).
        // Tapping presents the shared switcher menu; the switch itself is
        // picked up through `.activeProfileDidChange`, so this screen refreshes
        // whichever switcher was used.
        if switcherFactory != nil {
            let switcher = BarItems.icon(
                id: "profile.switcher", image: UIImage(systemName: "person.2"), label: "Switch Profile",
                menu: UIMenu(children: [])
            )
            switcher.tintColor = .label
            switcherItem = switcher
            // Pre-load profiles + avatars, then set a SYNCHRONOUS menu — its
            // content lands in the first frame, not popped in after the popover.
            reloadSwitcherMenu()
        }
    }

    /// Installs (or clears) the shell's trailing accessory. Safe before the
    /// view loads: the run is composed in `applyNavigationState`, which reads
    /// this every time it runs.
    func setTrailingAccessoryItem(_ item: UIBarButtonItem?) {
        trailingAccessoryItem = item
        guard isViewLoaded else { return }
        applyNavigationState()
    }

    /// Installs (or clears) the shell's leading accessory — the bell. Safe
    /// before the view loads: `applyNavigationState` reads it every time.
    func setLeadingAccessoryItem(_ item: UIBarButtonItem?) {
        leadingAccessoryItem = item
        guard isViewLoaded else { return }
        applyNavigationState()
    }

    // MARK: - History's day in the bar (#1344)

    /// The leading group: the tab root's bell, then — once the tray has
    /// scrolled away — the identity pill (#1590, the owner 2026-10-22: the
    /// profile's info goes LEFT; History's day went right).
    private var leadingItems: [UIBarButtonItem] {
        [leadingAccessoryItem, shownBarPill].compactMap { $0 }
    }

    /// History's day in the bar (#1344): the app's one section contract
    /// (#1573) — it mints the item (one per day, each with its own
    /// identifier, so UIKit morphs between them), places it, and never
    /// mid-push. A tap: the day's first post under the bar.
    ///
    /// - Someone else's profile: innermost of the TRAILING group (#1590) —
    ///   the identity pill holds the leading one — through
    ///   `setOwnTrailingBarItems`, so a bar toast that takes the group
    ///   (#1066) gives it back with the day in place.
    /// - The viewer's own (`dayLeads`): LEADING, after the bell (the owner,
    ///   2026-10-23, #1642) — the Messages inbox's arrangement. The leading
    ///   group is then the contract's to write.
    private lazy var sectionBinding: PinnedSectionBarBinding = {
        let binding = PinnedSectionBarBinding(
            viewController: self, placement: dayLeads ? .leading : .trailing, scope: "profile.history",
            separator: dayLeads ? nil : sectionSpacer
        )
        binding.onSelect = { [weak self] index in self?.galleryPager.scrollActivePageToSection(index) }
        return binding
    }()

    /// The day the page in front has scrolled into, as last published.
    private var pinnedSection: PostGridPinnedSection?

    /// The viewer's own profile — the tab root, the only one with account
    /// actions — names its day leading (#1642).
    private var dayLeads: Bool { onLogout != nil }

    /// Names `section` innermost of the trailing group, or takes the name
    /// away. No day over a page for no one (#1406): its gallery is gone.
    private func applyPinnedSection(_ section: PostGridPinnedSection?) {
        pinnedSection = section
        let shown = viewModel.namesNoOne ? nil : section
        sectionBinding.show(pinned: shown.map { ($0.index, .init(id: $0.title, title: $0.title, count: $0.count)) })
    }

    /// Puts the leading group — the bell, the pill — where the state says,
    /// ONCE, on the next turn: a scroll can move the tray twice in one turn,
    /// and a second write cut the first one's animation short.
    private func scheduleLeadingPlacement() {
        // The own profile's leading group is the contract's (#1642): it
        // defers the same way, with the day after these.
        guard !dayLeads else {
            sectionBinding.leadingPrefix = leadingItems
            return
        }
        guard view.window != nil else {
            navigationItem.leftBarButtonItems = leadingItems
            return
        }
        guard !leadingPlacementScheduled else { return }
        leadingPlacementScheduled = true
        DispatchQueue.main.async { [weak self] in self?.placeLeadingAfterTransition() }
    }

    /// ⚠️ NOT DURING A PUSH (#756): items set while the bar is in its push
    /// transition land with it, unanimated, when it ends. A placement due
    /// mid-transition waits for its end, then animates.
    private func placeLeadingAfterTransition() {
        if let coordinator = transitionCoordinator,
           coordinator.animate(alongsideTransition: nil, completion: { [weak self] _ in
               // Off the completion's turn, which still belongs to the transition.
               DispatchQueue.main.async { self?.placeLeadingAfterTransition() }
           }) {
            return
        }
        leadingPlacementScheduled = false
        if !(navigationItem.leftBarButtonItems ?? []).elementsEqual(leadingItems, by: ===) {
            navigationItem.setLeftBarButtonItems(leadingItems, animated: true)
        }
    }

    private var leadingPlacementScheduled = false

    #if DEBUG
    /// The bar's day item while it is shown — what a test reads.
    var debugSectionItem: UIBarButtonItem? {
        let shown = ownTrailingBarItems + (navigationItem.leftBarButtonItems ?? [])
        guard let item = sectionBinding.item, shown.contains(where: { $0 === item }) else { return nil }
        return item
    }

    /// History publishing the day it scrolled into. Tests.
    func debugApplyPinnedSection(_ section: PostGridPinnedSection?) { applyPinnedSection(section) }

    /// What a tap on the day item does. Tests.
    func debugTapSectionItem() {
        if let index = pinnedSection?.index { galleryPager.scrollActivePageToSection(index) }
    }
    #endif

    #if DEBUG
    /// Recomposes the trailing run, so a test can put the screen through the
    /// rebuild an injected item has to survive without having to move the
    /// follow state to get there.
    func debugRebuildNavigationState() { applyNavigationState() }
    /// The pages this profile has, and what its selector would call them.
    var debugPageCount: Int { galleryPager.pageOrder.count }
    var debugTabTitles: [String] { tabs.map(\.title) }
    /// What the selector reads, segment by segment. Tests.
    var debugSelectorTitles: [String] { selectorBar.currentTitles }
    var debugActivePageIndex: Int { galleryPager.activePageIndex }
    #endif

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
            headerView.render(.loading, profileKnown: false, animated: false)
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
    private func applyNavigationState(animated: Bool = false) {
        // ⚠️ **AND THE CHEVRON KEEPS ITS SILENCE.** A titled root gives every
        // screen pushed from it a WORDED back button, and two pushed bars were
        // budgeted against a bare 44pt chevron: `SearchResultsViewController`
        // says in as many words that its field would then be "44pt too
        // generous", and the chat thread's identity view is capped at 240pt on
        // the same assumption — 32 margins + 44 chevron + 24 gap + 8 padding +
        // 240 = 348 fits 375, while a "Messages" label (~98pt with its platter)
        // makes it ~402 and does not. `.minimal` keeps the title for this
        // screen and the chevron bare for the next one.
        navigationItem.backButtonDisplayMode = .minimal
        // ⚠️ **`.never`, OR THE TITLE IS NOT DRAWN AT ALL.** With the mode left
        // `.automatic` the bar rendered three platters and NO title label —
        // read straight off `-header-bar-tree`, which is how this was told from
        // a width problem: the string was set (`navItem=Demo Viewer`) and
        // simply had no label anywhere in the bar. For You and Messages both
        // state `.never` for their own reasons; this screen needs it because a
        // large title has nowhere to go under an immersive banner.
        navigationItem.largeTitleDisplayMode = .never

        // No content-source filter on any profile (#772): its sources are
        // pages at the foot, your own as anyone else's (#696).
        //   tab root  [bell] … [day][coins][switcher gear]
        //   pushed    [back][pill] … [day][coins][bell] (the pill once the
        //             tray has scrolled away, the day on History — #1590)
        // Written only when it changed — the same "say nothing" rule as the
        // trailing run below, for the same torn-capsule reason.
        let leading = leadingItems
        if dayLeads {
            // The contract writes the group, the day after the bell (#1642):
            // at once, as below, and only if it changed.
            sectionBinding.leadingPrefix = leading
            sectionBinding.placeNow()
        } else if !leadingPlacementScheduled,
           !(navigationItem.leftBarButtonItems ?? []).elementsEqual(leading, by: ===) {
            navigationItem.leftBarButtonItems = leading
        }
        // ⚠️ **WITHOUT THIS THE ITEM REPLACES THE BACK BUTTON**, and UIKit
        // disables the interactive pop along with it, silently. Harmless on the
        // tab root, which has no back button to supplement.
        navigationItem.leftItemsSupplementBackButton = true

        // ⚠️ **NO NAME IN THIS BAR, AND THE ISOLATION IS WHY.** It was asked
        // for and it does not fit: with the filter leading, no title renders at
        // all — not truncated, ABSENT. `-header-bar-tree` showed the three
        // platters and an empty `HostedViewContainer`; dropping the leading
        // item made the same label draw immediately, left-aligned, at its full
        // 106pt. This bar's trailing group is 223pt (gear+switcher share a
        // 115pt pill, the wallet wears its own 80pt platter) against For You's
        // ~115, and For You wears a leading glyph AND a title perfectly well.
        // So it is crowding here, not a rule about leading items.
        //
        // Three other explanations were tried against that symptom first and
        // all three were wrong: `largeTitleDisplayMode` (`.never` changed
        // nothing), the compression priority (`.defaultLow` → `.defaultHigh`,
        // nothing), and the unlaid-frame trap the accessory host records
        // (`sizeToFit`, nothing). Recorded so the next person does not spend
        // the same three builds on it.
        //
        // The identity block says the name in full a finger's width below, and
        // every item up here is a control.
        updateActionBarItem(followButtonState, animated: animated)
    }

    /// Whether the bar wears the bell right now.
    private var isShowingMuteBell: Bool {
        ownTrailingBarItems.contains { $0 === muteBellItem }
    }

    /// Recomposes the bar once no transition runs, without animation — for an
    /// item that has to leave (#800, #756).
    private func applyNavigationStateAtRest() {
        let apply: @MainActor () -> Void = { [weak self] in
            UIView.performWithoutAnimation { self?.applyNavigationState() }
        }
        if let navigationController { navigationController.whenAtRest(apply) } else { apply() }
    }

    /// Runs a navigation-bar mutation eagerly during an active transition:
    /// applied inside the transition coordinator's animation block it tracks
    /// the push/present frame-by-frame instead of snapping in after the
    /// animation completes. Outside a transition, an on-screen bar gets its
    /// items set ANIMATED — UIKit morphs them by identifier (#1679, R3),
    /// never a cross-dissolve of the bar's snapshot; off-screen it applies
    /// immediately. `change` is told which.
    private func alongsideTransition(_ change: @escaping (ProfileViewController, _ animated: Bool) -> Void) {
        // `animate(alongsideTransition:)` DROPS the block (returning false)
        // when the transition is already in its completion phase — the
        // coordinator is still non-nil there, so trusting its existence alone
        // loses updates that land in that window. Fall through when queueing
        // fails.
        if let coordinator = transitionCoordinator, coordinator.isAnimated,
           coordinator.animate(alongsideTransition: { [weak self] _ in
               guard let self else { return }
               change(self, false)
           }) {
            return
        }
        change(self, view.window != nil)
    }

    /// Installs the nav-bar relationship action per the current state, absent
    /// until the relationship is known. Plain titled items on purpose: iOS 26
    /// wraps bar items in the bar's own neutral Liquid Glass capsule — a
    /// glass-configured custom button here would stack a second material on
    /// top of it (a visible "double background" bleed), and `.done`/prominent
    /// styling floods the capsule with tint. The own-profile overflow menu
    /// keeps its slot next to it either way.
    private func updateActionBarItem(_ state: ProfileViewModel.FollowButton, animated: Bool = false) {
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
        // ⚠️ NO RELATIONSHIP ITEM UP HERE ANY MORE. Follow / Following sits
        // in the header's tray beside Message — see
        // `ProfileHeaderView.configureAction` — so the bar carries only the
        // own-profile chrome and whatever the shell injects. `state` still
        // arrives, because a rebuild is keyed on it and the guard below
        // decides whether anything actually changed.
        _ = state
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
        // ⚠️ THE LEADING GROUP IS NOBODY'S NOW, and the guard that used to
        // claim it for the docked selector had to be DELETED rather than left
        // to evaluate: with no selector item it reduced to
        // `leftBarButtonItems = []` on every appearance and every follow-state
        // change — a silent eraser of any leading item an owner installs, which
        // `configureNavigationBar` explicitly contemplates.

        // Relationship action for other users; the gear for own profile (where
        // `action` is nil).
        var items: [UIBarButtonItem] = []
        // A page for no one (#800, #1406) acts on no one: no bell, no
        // relationship, no balance. A pushed one keeps only its back button;
        // the viewer's own tab root keeps the gear and the switcher, its only
        // way to settings and to another profile.
        let namesNoOne = viewModel.namesNoOne
        if let settingsItem { items.append(settingsItem) }
        // The switcher, on the own profile only — see the note above for why it
        // is not in the leading group.
        if let switcherItem { items.append(switcherItem) }
        // The mute bell (#689), someone else's followed profile only: `[0]`
        // is the corner, as the gear is on your own. On screen, someone
        // else's profile reads `[pill][coins][bell]` once followed and
        // `[pill][coins]` before (#1451), the pill only once the tray has
        // scrolled away — never a Follow item: following from the bar is the
        // pill's "+".
        // ⚠️ THE PILL GOES LEADING (#1590): computed here, where the relation
        // is read, and placed by the leading group's own once-per-turn write.
        let pill = namesNoOne ? nil : barIdentityItem(for: followButtonState)
        if pill !== shownBarPill {
            shownBarPill = pill
            scheduleLeadingPlacement()
        }
        if namesNoOne {
            // Nothing to mute, follow or spend on.
        } else if showsMuteBell {
            muteBellItem.isEnabled = isMuteBellEnabled
            items.append(muteBellItem)
        }
        // The shell's accessory next: the gear keeps the corner and the
        // balance sits inboard — the Explore header's arrangement ([coins]
        // [search]). On a pushed profile, which has neither the gear nor the
        // switcher, the balance is the corner. Fixed spaces keep each its own
        // bubble — adjacent items share one glass capsule.
        if let trailingAccessoryItem, !namesNoOne {
            if showsMuteBell { items.append(muteBellSpacer) }
            items.append(trailingAccessoryItem)
        }
        // History's day, innermost (#1590), is the section contract's
        // (`sectionBinding`): it composes the group, the day after these. No
        // day over a page for no one (#1406): its gallery is gone.
        if namesNoOne, sectionBinding.item != nil { sectionBinding.show(pinned: nil) }
        // The load-bearing guard. A pop's `viewWillAppear` resolves to exactly
        // the item set already on the bar, and handing that same set back is
        // what used to tear the capsule down and rebuild it mid-transition.
        // Nothing changed, so nothing is said.
        let group = sectionBinding.placedTrailing(items)
        guard !ownTrailingBarItems.elementsEqual(group, by: ===) else {
            if !dayLeads { sectionBinding.trailingItems = items }
            return
        }
        // ⚠️ THE BELL ARRIVING waits for rest too, then comes in animated
        // (#1398): added mid-push it would pop in unanimated at the end
        // (#756).
        if showsMuteBell, !isShowingMuteBell, transitionCoordinator != nil {
            navigationController?.whenAtRest { [weak self] in
                guard let self else { return }
                updateActionBarItem(followButtonState, animated: view.window != nil)
            }
            return
        }
        // ⚠️ Items leaving a page for no one wait for rest: one removed
        // mid-push pops unanimated at its end (#756) — whichever call got
        // here first (a late relationship, the shell re-sending its balance).
        if namesNoOne, transitionCoordinator != nil {
            applyNavigationStateAtRest()
            return
        }
        #if DEBUG
        // Dev convenience: `-profile-navbar-audit` prints every *actual* bar
        // rebuild with the transition state it happened in. A rebuild logged
        // during a pop is the bug this guard exists to prevent, so the audit
        // is the regression test a recording can't be.
        if ProcessInfo.processInfo.arguments.contains("-profile-navbar-audit") {
            let phase = transitionCoordinator != nil ? "DURING-TRANSITION" : "idle"
            // `custom=` is the audit's other job: it counts items in this slot
            // that are HOSTED VIEWS rather than ones UIKit draws itself — the
            // shape that cannot interpolate across a bar transition.
            //
            // ⚠️ The floor is no longer zero. The shell's accessory (the wallet
            // badge) is a hosted view by necessity: a bar item cannot carry a
            // count beside a glyph. What the audit is still for is this
            // screen's OWN items — the follow capsule above all, which was
            // converted off a custom view for exactly this reason — so read it
            // as "one, and only the injected one".
            let custom = group.count(where: { $0.customView != nil })
            print("PROFILE-NAVBAR-AUDIT rebuild items=\(group.count) custom=\(custom) "
                + "state=\(followButtonState) \(phase)")
        }
        #endif
        // Written now, so they ride a push they arrive in; the contract
        // composes the group with the day and writes it through the toasts'
        // door — under bar toasts, the ones that come back (#1420, #1447).
        if dayLeads {
            // The day is leading here (#1642): the trailing group is all ours.
            setOwnTrailingBarItems(items, animated: animated)
        } else {
            sectionBinding.trailingItems = items
            sectionBinding.placeNow(animated: animated)
        }
    }

    /// The bar's identity pill, or nil: none until the tray has scrolled
    /// away, none on the viewer's own profile. Its badge says the relation
    /// (#1451).
    private func barIdentityItem(for state: ProfileViewModel.FollowButton) -> UIBarButtonItem? {
        guard isTrayScrolledAway, !viewModel.isOwnProfile, !identityStubIsSelf,
              makeEditViewController == nil else { return nil }
        guard let badge = Self.barBadge(for: state, mutual: viewModel.isMutualFollow),
              let profile = viewModel.profile, let barIdentityPill, let barIdentityItem else { return nil }
        barIdentityPill.setPerson(
            id: profile.id, name: profile.displayName, meta: "@\(profile.handle)",
            avatarURL: profile.avatarURL, pipeline: imagePipeline
        )
        barIdentityPill.setFollowBadge(badge, animated: barIdentityPill.view.window != nil)
        // Never narrower than its face.
        barIdentityPill.setWidthBudget(max(PersonPill.wrapperHeight, floor(barIdentityWidthBudget())))
        return barIdentityItem
    }

    /// The badge for the relation (#1451) — the post page's states: "+"
    /// while not followed, pending while asked, following, friends when
    /// mutual. Nil: no pill (a profile the viewer cannot follow).
    static func barBadge(for state: ProfileViewModel.FollowButton, mutual: Bool) -> PersonPill.Badge? {
        switch state {
        case .follow: .follow
        case .requested: .pending
        case .following: mutual ? .friends : .following
        default: nil
        }
    }

    /// The bar's width less the back button and the trailing group — the
    /// balance, the bell, History's day — with the bar's margins and gaps.
    private func barIdentityWidthBudget() -> CGFloat {
        let barWidth = navigationController?.navigationBar.bounds.width ?? view.bounds.width
        var others: CGFloat = Self.barControlSide // the back button
        if let accessory = trailingAccessoryItem?.customView {
            // A badge laid out by constraints has no intrinsic width: fit it.
            let intrinsic = accessory.intrinsicContentSize.width
            others += intrinsic > 0
                ? intrinsic
                : accessory.systemLayoutSizeFitting(UIView.layoutFittingCompressedSize).width
        }
        if showsMuteBell { others += Self.barControlSide }
        if let title = sectionBinding.item?.title {
            // The day's glass bubble: its title and the bubble's own padding.
            let font = UIFont.appFont(forTextStyle: .body)
            others += ceil((title as NSString).size(withAttributes: [.font: font]).width) + Spacing.lg * 2
        }
        // ⚠️ LEADING, THE BAR KEEPS MORE AIR (#1590): between the two groups
        // UIKit reserves the title's slot, and a pill sized to the trailing
        // gaps alone made it fold the balance and the bell into an overflow
        // "•••" on an SE.
        let gaps = Spacing.md * 4 + Spacing.lg * 2 + Self.leadingGroupAir
        return barWidth - others - gaps
    }

    private static let barControlSide: CGFloat = 44
    /// The extra room the bar keeps between a leading pill and the trailing
    /// group (#1590), measured on an SE.
    static let leadingGroupAir: CGFloat = 40

    /// Whether the header's action tray is out of sight: under the
    /// navigation bar, by the header's coming position (`travelled` — the
    /// constraint moves it on the next layout pass), or faded with the
    /// identity block. The header stops climbing once its selector docks, so
    /// the tray's foot can rest at the bar's edge; by then the identity fade
    /// (`applyIdentityFade`, run first) has taken it out.
    /// Wires the selector and the source filter, and puts the selector in its
    /// inline slot: a format tab records the selection and pages the gallery; a
    /// source pick re-filters every page in place.
    private func configureFilterTray() {
        guard viewModel.hasGallery else { return }

        // Both ways (`HeroPageSelector.bind`): the lens tracks the pages, the
        // pill scrubs them, a reselect goes back to the top of the tab.
        selector.bind(to: galleryPager) { [weak self] index in self?.barSelectionChanged(index) }

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

    }

    /// A tap on either selector: record the format, page the gallery, and carry
    /// the choice to the other bar so the hand-over has nothing to reconcile.
    private func barSelectionChanged(_ index: Int) {
        mirrorSelection(to: index)
        let tab = tabs[index]
        adoptTab(tab)
        galleryPager.setActivePage(tab, animated: selector.bar.animatesPageChanges)
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

    /// Records the choice.
    ///
    /// ⚠️ Only a FORMAT page is a filter preference. Saved and Liked are
    /// corpora, not formats, and writing one into the stored filter would mean
    /// re-opening the profile on a tab the next profile may not even have.
    private func adoptTab(_ tab: ProfileTab) {
        viewModel.setActiveTab(tab)
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
    /// Puts the strip on a selection the pager reached by itself.
    ///
    /// ⚠️ THE RE-ENTRANCY LATCH WENT WITH THE SECOND COPY. It existed because
    /// `select` fires `.valueChanged`, whose action mirrored into the other
    /// bar, which selected again. With one strip the guard below is all of it.
    private func mirrorSelection(to index: Int) {
        selector.select(index)
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



    /// Puts the selector at the foot of the screen, in a `UITabAccessory` —
    /// on BOTH profiles.
    ///
    /// ⚠️ **A PUSHED SCREEN CAN HOST ONE, AND THE COMMIT THAT SAID OTHERWISE
    /// WAS WRONG.** "A pushed screen has no tab bar to hang an accessory from"
    /// is the sentence that sent this branch to the toolbar; the search
    /// results — which also sets `hidesBottomBarWhenPushed` — then measured the
    /// opposite: `env=regular`, a 360x48 container at the foot, laid out
    /// exactly as on a tab root. `UITabAccessory.h` says so too, defining
    /// `.regular` as "above the bottom tab bar when it is visible; **or, at the
    /// bottom of the UITabBarController's view**".
    ///
    /// ⚠️ **`trayPlacement` IS THE ONLY THING THAT CAN ANSWER THIS, and it is
    /// injected for that reason.** Its own note says why: "the host knows, and
    /// the screen cannot work it out for itself (a nav root inside a tab bar
    /// and a pushed screen look identical from in here)". Two other questions
    /// look like this one and are not it — `onLogout != nil` is whether this is
    /// the canonical account entry point, and `viewModel.isOwnProfile` is
    /// whether it is the viewer. A ROUTED self profile is own-profile, wears
    /// five tabs and an Edit button, and is PUSHED: choosing by
    /// `isOwnProfile` would hang a shell-lifetime accessory on a screen with
    /// `hidesBottomBarWhenPushed = true`, which is the measured leak the
    /// accessory's install/remove bracket exists to prevent.
    ///
    /// ⚠️ ONE PAGE, NO SELECTOR (#631). Anyone else's profile has only Posts,
    /// and a strip with one segment is a label pretending to be a control.
    ///
    ///
    /// ⚠️ **TWO HOMES, BY WHERE THE PROFILE IS (#728, the owner's call
    /// 2026-10-09).** #718 floated the strip in this view at its intrinsic
    /// width on both; that was not the ask.
    /// - The Profile **tab root** keeps it in the tab bar's `UITabAccessory`,
    ///   as it always had.
    /// - A **pushed** profile hosts it as a toolbar item at the bottom leading
    ///   corner, at its intrinsic width — the relations screen's arrangement:
    ///   the item's platter is the glass, so the strip draws none
    ///   (`.platter`).
    private func placeSelectors() {
        guard viewModel.hasGallery, tabs.count > 1 else { return }
        selector.place(on: self)
    }

    /// Takes the selector away when one tab is left (#742).
    private func removeSelectors() {
        selector.remove(from: self)
    }

    /// The tabs whose source is still loading and which had posts the last
    /// time this profile was seen (`SectionPresenceStore`, #1773).
    static func rememberedTabs(
        _ tabs: [ProfileTab], in snapshot: ProfileViewModel.GallerySnapshot,
        screen: String?, presence: SectionPresenceStore
    ) -> [ProfileTab] {
        guard let screen else { return [] }
        return tabs.filter { tab in
            snapshot.state(for: tab) == .loading
                && (presence.count(screen: screen, section: String(describing: tab)) ?? 0) > 0
        }
    }

    /// ⚠️ NO TAB FOR A SOURCE WITH NOTHING IN IT (#742, the owner's call
    /// 2026-10-09) — Posts included since #1422 (owner, 2026-10-19). A tab
    /// shows once its source holds something; a source still loading waits,
    /// rather than showing a tab that might leave. Two exceptions:
    /// - the viewer's OWN Posts stays even empty: it is where the invitation
    ///   to post belongs;
    /// - with nothing shown at all, Posts is the one page — loading, "No
    ///   Posts Yet", or the lock of a private profile — so the area under
    ///   the header is never blank, which reads as still loading.
    ///
    /// A private profile the viewer does not follow thus shows Tagged alone
    /// when it has posts, plainly — no lock line (#1445) — and the lock alone
    /// when it has none; following it brings the tabs back as their sources
    /// fill. One tab left is no selector at all, in the tab
    /// bar's accessory as in a pushed profile's toolbar.
    private func showTabs(for snapshot: ProfileViewModel.GallerySnapshot) {
        var shown = Self.shownTabs(allTabs, in: snapshot, isOwnProfile: viewModel.isOwnProfile)
        // ⚠️ SECTIONS BY PRESENCE (#1773): a source still loading whose tab
        // had posts last time keeps its tab from the first frame — it does
        // not pop in when its source answers.
        let remembered = Self.rememberedTabs(
            allTabs, in: snapshot, screen: viewModel.presenceScreen, presence: galleryPager.presence
        )
        shown = allTabs.filter { shown.contains($0) || remembered.contains($0) }
        if shown.isEmpty { shown = [.format(.activity)] }
        guard shown != tabs else { return }
        let active = tabs.indices.contains(galleryPager.activePageIndex) ? tabs[galleryPager.activePageIndex] : nil
        tabs = shown
        galleryPager.setVisibleTabs(shown)
        selectorBar.setTitles(shown.map(\.title))
        let index = active.flatMap { shown.firstIndex(of: $0) } ?? 0
        mirrorSelection(to: index)
        // ⚠️ THE PAGE ON SCREEN IS ADOPTED WHEN ITS TAB WENT (#772). An account
        // switch on Reposts or Tagged cuts the tabs to Posts while every source
        // reloads; the strip clamps quietly and the pager settles nothing, so
        // the source stayed on the tab that left — Posts then paged and pushed
        // "View all" from the wrong corpus.
        if active != shown[index] { adoptTab(shown[index]) }
        if shown.count > 1 {
            let wasPlaced = selector.isPlaced
            placeSelectors()
            // ⚠️ ON SCREEN, NOT IN A WINDOW. A tab that arrives while a pushed
            // screen (Settings) is covering this one found the view still in
            // the window mid-push, installed the band, and nothing ever took
            // it down: this screen's `viewWillDisappear` had already run with
            // no band to remove. The next `viewWillAppear` puts it up.
            guard !wasPlaced, isShownOnScreen else { return }
            // Arrived while on screen: up now, not at the next appearance.
            selector.install(on: self, alongside: nil)
            if navigationController?.topViewController === self {
                selector.showToolbar(for: self, animated: true)
            }
        } else {
            removeSelectors()
        }
    }

    /// The tabs `snapshot` gives something to show, in `all`'s order (#742,
    /// #1422): those whose source holds posts, and the viewer's own Posts.
    /// Empty when nothing has posts yet — `showTabs` then shows Posts alone.
    static func shownTabs(
        _ all: [ProfileTab], in snapshot: ProfileViewModel.GallerySnapshot, isOwnProfile: Bool
    ) -> [ProfileTab] {
        all.filter { tab in
            if tab == .format(.activity), isOwnProfile { return true }
            if case .content(let posts) = snapshot.state(for: tab) { return !posts.isEmpty }
            return false
        }
    }

    // MARK: - The hero page's contract

    /// A pull released past its threshold, or a page asking.
    override func heroPageRefresh() {
        viewModel.refresh()
    }

    /// A profile with no gallery (a page for no one) needs no air under it.
    override var heroPageBottomBreathingRoom: CGFloat { viewModel.hasGallery ? 8 : 0 }

    /// Once the tray has scrolled under the bar, the bar carries the
    /// profile's identity (#1451) — and gives it back on the way down.
    override func heroPageHeaderDidMove(travelled: CGFloat) {
        let trayGone = isActionRowUnderBar(travelled: travelled)
        guard trayGone != isTrayScrolledAway else { return }
        isTrayScrolledAway = trayGone
        updateActionBarItem(followButtonState, animated: view.window != nil && transitionCoordinator == nil)
    }

    #if DEBUG
    /// Whether the banner's loop is wanted now (#1399) — what a test reads.
    var debugBannerVideoShouldPlay: Bool { bannerVideoShouldPlay }
    #endif


    // MARK: - Render

    private func render(_ phase: ProfileViewModel.Phase) {
        let previous = renderedPhase
        renderedPhase = phase
        defer { noteLandingMilestone() }
        switch phase {
        case .loading:
            // First load renders the REAL screen in skeleton state: the
            // header redacts in place (same views, same constraints — see
            // `ProfileHeaderView.setRedacted`), and the gallery pages shimmer
            // through their own loading state until the view model's first
            // snapshot arrives. Hydration is a pure cross-fade over the very
            // frames the content will occupy — nothing can shift.
            statusView.isHidden = true
            galleryPager.isHidden = false
            // The HEADER is held on a switch rather than redacted: its bones'
            // shimmer sweeps left to right, and over a fast load that sweep
            // became the transition — a diagonal wipe across the identity.
            // The GALLERY still redacts, because its rows are genuinely
            // unknown until the fetch lands and bones are the honest answer.
            headerView.render(phase, profileKnown: viewModel.profile != nil, switching: isSwitchingProfile, animated: false)
            if viewModel.hasGallery {
                skeletonViewportFill?.isActive = true
                galleryPager.render(ProfileViewModel.GallerySnapshot(
                    activity: .loading, media: .loading, isComplete: false,
                    reposts: .loading, tagged: .loading,
                    repostsComplete: false, taggedComplete: false
                ))
            }

        case .seeded(let seed):
            // The person as the origin showed them (#1859): the header draws
            // their identity, its counters wait; the gallery is on its bones,
            // as on a first load.
            statusView.isHidden = true
            galleryPager.isHidden = false
            if currentHandle == nil { currentHandle = seed.handle ?? seed.displayName }
            headerView.render(phase, profileKnown: false, switching: false, animated: false)
            if viewModel.hasGallery {
                skeletonViewportFill?.isActive = true
                galleryPager.render(ProfileViewModel.GallerySnapshot(
                    activity: .loading, media: .loading, isComplete: false,
                    reposts: .loading, tagged: .loading,
                    repostsComplete: false, taggedComplete: false
                ))
            }

        case .content(let model):
            pullIndicator.endRefreshing()
            statusView.isHidden = true
            galleryPager.isHidden = false
            // Content owns its height again; the release rides the same
            // layout pass as the (dissolve-masked) gallery height snap.
            skeletonViewportFill?.isActive = false
            // Instagram-style: the @handle is the screen's title (the header
            // shows the bold display name). "Profile" only until first load.
            // Content usually lands mid-push; rebind inside the transition
            // so the bar text doesn't snap in after the animation settles.
            currentHandle = model.handle
            // ⚠️ Once. The bar's state does not follow the model, and a
            // refresh re-rendering content cross-dissolved the whole bar —
            // a snapshot of it — for nothing.
            if case .content = previous {} else {
                alongsideTransition { $0.applyNavigationState(animated: $1) }
            }
            // Content first — the labels adopt their text while still
            // invisible under the bones — then the alpha-only reveal.
            // Granular on a switch: each header group dissolves on its own,
            // lightly staggered, so one identity becomes another rather than
            // the whole screen blinking over at once.
            headerView.render(
                phase, profileKnown: true, switching: isSwitchingProfile, animated: view.window != nil
            )
            updateBannerVideo()

        case .failed(let message):
            pullIndicator.endRefreshing()
            // Never leave the previous profile held over an error.
            galleryPager.isHidden = true
            skeletonViewportFill?.isActive = false
            // Nothing ever loaded (an offline handle tap, #800): no header
            // around the block (`ProfileHeaderView.render`).
            headerView.render(phase, profileKnown: viewModel.profile != nil, animated: false)
            // ⚠️ A WAY OUT (#797): the pull lives on the gallery this hides,
            // so "Pull to retry" could not be done.
            statusView.configure(
                symbolName: "exclamationmark.triangle", title: message,
                actionTitle: "Try Again", actionHandler: { [weak self] in
                    self?.statusView.setActionBusy(true)
                    self?.viewModel.refresh()
                }
            )
            statusView.isHidden = false

        case .notFound(let message, let detail):
            // The same block as a failure, without Try Again: an answer, not
            // an error (#800). The header goes too — with no profile its
            // verified badge, counter labels and Message button showed
            // through around the block, a page for no one.
            //
            // ⚠️ A PLAIN PAGE (#1406, the owner 2026-10-18): the banner card
            // goes with the header, in this same pass (`ProfileHeaderView.
            // isHidden`) — a revisit that opened on the cached profile must
            // not show it a frame longer — and the bar keeps only the back
            // button.
            pullIndicator.endRefreshing()
            galleryPager.isHidden = true
            skeletonViewportFill?.isActive = false
            headerView.render(phase, profileKnown: viewModel.profile != nil, animated: false)
            statusView.configure(
                symbolName: "person.crop.circle.badge.questionmark", title: message, subtitle: detail
            )
            statusView.isHidden = false
            // The bell worn since frame 0, the shell's balance and a day's
            // name have no one to act on: the bar recomposes once no
            // transition runs (an item leaving mid-push pops unanimated). It
            // says nothing when nothing changed.
            applyNavigationStateAtRest()
        }
    }
}

// MARK: - Landing milestones

extension ProfileViewController {
    /// Whether the page on screen is the page that stays: the header
    /// has its profile, the follow capsule has its answer (and, for someone
    /// followed, the map pin its rails — it widens the tray), both pictures are
    /// drawn (or known absent), and the gallery's open page has left its
    /// bones. A failed load is settled too — nothing more is coming.
    ///
    /// The cards' own media are NOT waited for: those are per item, P13.
    var isSettled: Bool {
        switch renderedPhase {
        case .loading, .seeded: return false
        case .failed, .notFound: return true
        case .content:
            let relationshipKnown = followButtonState != .hidden || viewModel.isRelationshipSettled
            return relationshipKnown && viewModel.isMapPinSettled
                && headerView.arePicturesSettled && isGallerySettled
        }
    }

    private var isGallerySettled: Bool {
        guard viewModel.hasGallery else { return true }
        guard let snapshot = lastGallerySnapshot, tabs.indices.contains(galleryPager.activePageIndex) else {
            return false
        }
        return snapshot.state(for: tabs[galleryPager.activePageIndex]) != .loading
    }

    /// One piece of the first frame landed. Nothing waits on these any more —
    /// the screen is pushed at once on its loading state (#778) — so this only
    /// traces them (`-profile-first-frame-log`).
    func noteLandingMilestone() {
        #if DEBUG
        traceReadiness()
        #endif
    }
}

#if DEBUG
extension ProfileViewController {
    /// What a refresh landing touched: header applies, gallery reloads and
    /// re-dressed items, and whether any page fell back to its bones.
    var debugHeaderConfigureCount: Int { headerView.debugConfigureCount }
    var debugGalleryReloadCount: Int { galleryPager.debugReloadCount }
    var debugGalleryReconfiguredItems: Int { galleryPager.debugReconfiguredItems }
    var debugGalleryRecountedItems: Int { galleryPager.debugRecountedItems }
    var debugGalleryShowsSkeleton: Bool { galleryPager.debugShowsSkeleton }
    var debugIsRefreshing: Bool { pullIndicator.debugIsRefreshing }
    /// The content inset the pages were handed — the header's height.
    var debugHeaderHeight: CGFloat { headerHeight }
    /// The same, measured afresh — what the cached answer must agree with.
    var debugMeasuredHeaderHeight: CGFloat { measuredHeaderHeight }

    /// `-profile-first-frame-log`: each readiness milestone as it lands,
    /// stamped from the screen's construction — what a held push is waiting
    /// on, by name.
    fileprivate func traceReadiness() {
        guard ProcessInfo.processInfo.arguments.contains("-profile-first-frame-log") else { return }
        let phase: String = switch renderedPhase {
        case .loading: "loading"
        case .seeded: "seeded"
        case .content: "content"
        case .failed: "failed"
        case .notFound: "notFound"
        }
        let state = "phase=\(phase) relationship=\(followButtonState != .hidden || viewModel.isRelationshipSettled) "
            + "pin=\(viewModel.isMapPinSettled) "
            + "pictures=\(headerView.arePicturesSettled) gallery=\(isGallerySettled)"
        guard state != lastTracedReadiness else { return }
        lastTracedReadiness = state
        let ms = (CACurrentMediaTime() - debugBornAt) * 1000
        print(String(format: "[profile-ready] +%.0fms ", ms) + state)
    }
}

#endif

#if DEBUG

#endif

extension ProfileViewController {
    /// "View all" under one of Posts' chunks: the profile's photos and videos
    /// as the media mosaic (#631) — what the Gallery tab was.
    ///
    /// Fed from here as pages land (`onGalleryChange`), under the same
    /// source, and its posts open through `openGalleryPost` measured against
    /// ITS mosaic, so a close lands on the tile it left from.
    /// What "View all" pushes is the page on screen's media (#696): Reposts
    /// and Tagged have their own, on every profile since #772.
    private var mediaGalleryTitle: String {
        switch tabs[galleryPager.activePageIndex] {
        case .reposts: "Reposted Media"
        case .tagged: "Tagged Media"
        default: ProfileTab.format(.media).title
        }
    }

    func pushMediaGallery() {
        guard navigationController?.transitionCoordinator == nil else { return }
        let savesPosts = viewModel.bookmarks != nil
        let gallery = ProfileMediaGalleryViewController(
            handle: currentHandle, title: mediaGalleryTitle
        ) { [makeGridPage] style in makeGridPage(style, savesPosts) }
        gallery.loadViewIfNeeded()
        gallery.render(lastGallerySnapshot?.media ?? .loading)
        gallery.onOpen = { [weak self, weak gallery] post, stream, showingComments in
            guard let self, let gallery else { return }
            openGalleryPost(
                post, stream: stream, showingComments: showingComments,
                from: gallery.grid, presenter: gallery, format: .media
            )
        }
        gallery.onNearEnd = { [weak self] in self?.viewModel.loadMoreGallery() }
        // ⚠️ THE LIST ON SCREEN IS THE MEDIA NOW, and the model pages for it:
        // a page of text posts adds no tile here, so no tile would come on
        // screen to ask for the next one — the model reads on instead, as it
        // does for whichever list is showing (`appendGalleryPages`).
        viewModel.setGalleryFormat(.media)
        gallery.onClose = { [weak self] in self?.viewModel.setGalleryFormat(.activity) }
        mediaGallery = gallery
        navigationController?.pushViewController(gallery, animated: true)
    }

    /// Opens a gallery post — from its card, or from its comment chip with the
    /// thread already up (`showingComments`, never set for a text post: its
    /// page IS its thread).
    ///
    /// `surface` is the list it was tapped in — the profile's pager unless
    /// said otherwise, or the media gallery its "View all" pushed (#631),
    /// which then also `presents` the feed and names its `format` for the
    /// feed's continuation.
    func openGalleryPost(
        _ post: GalleryPost, stream: [GalleryPost], showingComments: Bool,
        from surface: (any PostGridPage)? = nil,
        presenter: UIViewController? = nil,
        format: GalleryFilter.Format = .activity
    ) {
        let presenter = presenter ?? self
        // One opening at a time: a second tap while the first push is in the
        // air pushed a second feed over it.
        guard navigationController?.transitionCoordinator == nil else { return }
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
        guard let page = surface ?? galleryPager.activePage else { return }
        // ⚠️ THE ONE TILE CONTRACT (#1273, epic #1269): For You's page
        // describes its tile — a take-off playing, the playhead continued on
        // a same-post close (this used to restart the clip), the tile's own
        // parked clip after paging on, the words faded in on a close, the
        // tile's or the card's window when there is no picture to fly.
        let origin = page.heroOrigin(
            opening: post, stream: window, in: presenter.view,
            textReveal: page.closeWindow(
                for: post, alignsPageToSource: true,
                willStageDismissal: {},
                dismissalDidEnd: { _ in }
            ),
            opensComments: showingComments,
            willStageDismissal: {},
            // The header floats over pages whose insets never move while a
            // post covers them (`contentInsetAdjustmentBehavior = .never`).
            pinsBeforeClose: false,
            continuation: { [weak self] after in
                await self?.viewModel.galleryPostIDs(after: after, in: format)
            }
        )
        feedHero(window.map(\.id), presenter, origin)
        // ⚠️ A REFUSED OPEN PUSHES NOTHING (the stack mid-transition), and the
        // scope opened above would then hold this still-visible grid silent:
        // only the screen's next appearance ends it, and it never disappeared.
        // The push is synchronous, so the stack already says which happened.
        if let navigation = presenter.navigationController,
           navigation.topViewController === presenter, presenter.presentedViewController == nil {
            page.endPlaybackHandoff()
        }
    }
}

// MARK: - Tab re-tap (#1309)

extension ProfileViewController: TabReselectScrolling {
    /// Back to the PROFILE's top — the identity and its tray at rest, as the
    /// bar's identity pill does — not merely the active tab's first row.
    func scrollToTopForTabReselect() {
        galleryPager.scrollActivePageToHeaderTop()
    }
}

// MARK: - The native back swipe (#1324)

/// ⚠️ A PROFILE IS A PLAIN PUSH, SO IT POPS WITH THE SYSTEM'S SWIPE. It used to
/// carry a custom slide only because UIKit vetoed its own full-surface swipe
/// under a stack delegate; the shell now lifts that veto (`ContentPopDelegateProxy`),
/// and this screen keeps only its own limits on where the swipe may begin:
/// the whole surface on the first tab, never a drag a carousel takes.
extension ProfileViewController: ContentPopGating {
    func allowsContentPop(beginningAt point: CGPoint, in view: UIView) -> Bool {
        guard let nav = navigationController,
              ProfileDismissalPolicy.allowsFullWidthDismissal(
                  activeIndex: galleryPager.activePageIndex,
                  isPushed: nav.viewControllers.first !== self
              )
        else { return false }
        return ProfileDismissalPolicy.dragMayDismiss(originX: point.x) {
            MediaCarouselTouchRouting.dragPassesThroughCarousel(at: point, in: view, towardsPageDelta: -1)
        }
    }
}
