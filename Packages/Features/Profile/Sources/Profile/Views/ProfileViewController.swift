import CoreModels
import CoreNavigation
import CoreStorage
import DesignSystem
import FeedInterface
import HeroPage
import LaunchArguments
import MapsInterface
import MediaCore
import MediaPlayback
import PostGrid
import ProfileData
import ProfileInterface
import SettingsInterface
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
    let makeGridPage: ProfileGridPageFactory

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
    /// The origin said this profile is the viewer's own.
    private let identityStubIsSelf: Bool
    /// Builds the account settings screen (own profile only, the gear's
    /// destination). Nil for other users.
    private let makeSettingsViewController: (() -> UIViewController)?
    /// Builds the reusable profile-switcher menu (own profile only). Nil for
    /// other users — switching is a viewer affordance.
    let switcherFactory: ProfileSwitcherMenuFactory?
    /// Builds the followers / following screen for a subject and a starting
    /// tab. Nil when the app wasn't wired with a relationships repository, in
    /// which case the counters stay inert rather than opening an empty screen.
    private let makeRelationshipsViewController: (
        (ProfileRelationshipsViewModel.Subject, RelationshipDirection) -> UIViewController
    )?

    /// Retained for the share sheet, which builds its own QR card (and a
    /// throwaway one to rasterize) and needs the same avatar cache.
    let imagePipeline: ImagePipeline
    /// The player pool, kept for the media gallery "View all" pushes (#631).
    private let videoPlayback: VideoPlaybackController?
    /// Opening a post, and the media gallery "View all" pushes
    /// (`ProfilePostOpening`, #2522).
    private(set) lazy var postOpening = ProfilePostOpening(host: self)
    /// Supplies the share sheet's quick-send row; nil hides it.
    let shareTargeting: (any ProfileShareTargeting)?
    /// Internal (not private) only for the +QA hooks.
    let headerView: ProfileHeaderView
    /// Internal (not private) only for the +QA hooks.
    let galleryPager: ProfileGalleryPagerView
    /// Flies a tapped post into the unified feed. Injected rather than built
    /// here: the card and the transition belong to the feed feature, and this
    /// screen only describes where the post is (see `SnapFeedHeroOrigin`).
    /// Nil leaves every tap on the plain route, which still opens the feed.
    var feedHero: (([PostID], UIViewController, SnapFeedHeroOrigin) -> Void)?
    /// The gallery cards' stakes — see `PostCardStaking`.
    var staking: PostCardStaking? {
        didSet { galleryPager.staking = staking }
    }
    /// The tabs on show at construction — Posts alone; `ProfileTabPages`
    /// owns them from there.
    private let initialTabs: [ProfileTab]
    /// Every tab this profile can have.
    let allTabs: [ProfileTab]
    /// The Channels tab's model (#2232): the channels this profile owns,
    /// read through Chat's seam. Nil with the channels off — no tab at all.
    /// Internal for tests.
    let channels: ProfileChannelsViewModel?
    /// The new channel's sheet, for the own tab's "Create a Channel" (#2232).
    let makeChannelCreation: (@MainActor () -> UIViewController?)?
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
    private var didSubordinatePagerToPop = false
    #if DEBUG
    /// The launch-argument hooks (`ProfileDebugHooks`, #2522), armed once
    /// from `viewDidAppear`.
    private(set) lazy var debugHooks = ProfileDebugHooks(host: self)
    /// Whether this profile has an editor, and settings: the viewer's own.
    var hasEditor: Bool { makeEditViewController != nil }
    var hasSettings: Bool { makeSettingsViewController != nil }
    #endif

    /// The own-profile settings gear; pushes Settings (`SettingsFeatureBuilding`).
    private var settingsItem: UIBarButtonItem?
    /// Keeps the corner item — Follow or Requested (#2248) — and the shell's
    /// balance two bubbles: iOS 26 groups adjacent bar items into one platter
    /// (the feed's note on `setEngagedChrome`). One space for both, since
    /// only one of them stands at a time, and none with the corner empty.
    /// Kept: the trailing run is compared by reference (the bar's
    /// identical-group guard), so a fresh item is a rebuild.
    private let cornerSpacer = UIBarButtonItem.fixedSpace(Spacing.sm)
    /// Keeps History's Select / Done — standing in the gear's place (#2307)
    /// — its own bubble, apart from the balance.
    private let historySelectSpacer = UIBarButtonItem.fixedSpace(Spacing.sm)
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
    /// then carries the profile's Follow (or Requested) in its corner — at
    /// exactly the point the identity pill used to come in (#1451, #2248),
    /// so the page never shows two Follows at once. On the viewer's own
    /// profile, History's Select takes the gear's place then (#2307).
    private(set) var isTrayScrolledAway = false
    /// Keeps History's day in its own bubble, inboard of the trailing group.
    private let sectionSpacer = UIBarButtonItem.fixedSpace(Spacing.sm)
    /// The bar's Follow, in the corner where the bell stands once the
    /// profile is followed (#2248, the owner 2026-11-10) — replacing the
    /// identity pill whose "+" was the bar's only Follow (#1451).
    ///
    /// **A stock titled item (`BarItems.title`) — deliberately not a
    /// custom-view item, and not a `UIButton` of any kind.** Two independent
    /// reasons, and both have bitten this screen:
    ///
    /// 1. *Rendering.* The iOS 26 bar wraps every item in its own Liquid Glass
    ///    capsule. A glass-configured button hosted as a custom view stacks a
    ///    second material inside that capsule — a visible double-background
    ///    bleed. Handing UIKit a title and letting it draw the chrome is the
    ///    only way to get exactly one capsule.
    /// 2. *Transitions.* A custom view is opaque to the bar's push/pop
    ///    choreography: UIKit can cross-fade and slide items it owns, but a
    ///    hosted view is just a subview it has to carry, which is what makes
    ///    custom bar items snap while native ones interpolate.
    ///
    /// Kept, as the bell is: the trailing run is compared by reference (the
    /// bar's identical-group guard), so a fresh item would be a rebuild.
    private lazy var followBarItem = makeRelationshipBarItem(requested: false)
    /// Requested, on a private profile the viewer asked to follow: its own
    /// item under its own identifier, so the bar morphs Follow into it
    /// (#1679, R3). A tap withdraws the request, as the tray's does.
    private lazy var requestedBarItem = makeRelationshipBarItem(requested: true)

    /// The loaded profile's @handle — the bar's title once known (#2248).
    /// Stashed so `viewWillAppear` can bind the bar from current state before
    /// the push animation starts, whenever the data beat the transition; a
    /// change once the view is up rides the transition it lands in.
    private(set) var currentHandle: String? {
        didSet {
            guard currentHandle != oldValue, isViewLoaded else { return }
            alongsideTransition { screen, _ in screen.applyBarTitle() }
        }
    }

    /// Internal (not private) only for the +QA hooks.
    private(set) var followButtonState: ProfileViewModel.FollowButton = .hidden

    /// The phase last rendered.
    private var renderedPhase: ProfileViewModel.Phase = .loading
    /// The gallery as last rendered.
    private(set) var lastGallerySnapshot: ProfileViewModel.GallerySnapshot?
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
    /// The app's viewer channel (#2376), whose profile switches this screen
    /// follows, whichever switcher made them. Nil (tests): none is heard.
    let viewerEvents: ViewerEvents?
    /// The account switcher on the own profile's name (`ProfileAccountSwitcher`, #2522).
    private(set) lazy var accountSwitcher = ProfileAccountSwitcher(host: self)

    init(
        viewModel: ProfileViewModel,
        imagePipeline: ImagePipeline,
        videoPlayback: VideoPlaybackController? = nil,
        makeGridPage: @escaping ProfileGridPageFactory,
        presence: SectionPresenceStore,
        shareTargeting: (any ProfileShareTargeting)? = nil,
        onLogout: (() -> Void)?,
        makeEditViewController: ((UserProfile?, @escaping () -> Void) -> UIViewController)? = nil,
        makeSettingsViewController: (() -> UIViewController)? = nil,
        switcherFactory: ProfileSwitcherMenuFactory? = nil,
        makeRelationshipsViewController: (
            (ProfileRelationshipsViewModel.Subject, RelationshipDirection) -> UIViewController
        )? = nil,
        identityStub: ProfileIdentityStub? = nil,
        trayPlacement: ProfileTrayPlacement = .navigationToolbar,
        channels: ProfileChannelsViewModel? = nil,
        makeChannelCreation: (@MainActor () -> UIViewController?)? = nil,
        viewerEvents: ViewerEvents? = nil
    ) {
        self.viewerEvents = viewerEvents
        self.trayPlacement = trayPlacement
        self.channels = channels
        self.makeChannelCreation = makeChannelCreation
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
        // The header closes with the posts' hairline (#2289), over every tab.
        header.drawsFootHairline = true
        headerView = header
        // Every profile can carry Saved and Liked (#411, #837): someone
        // else's only when its owner shows them — the server answers empty
        // otherwise, and an empty source is no tab (#742).
        // Channels only with its model (#2232): the flag off, no tab can show.
        let allTabs = ProfileTab.ownTabs.filter { $0 != .channels || channels != nil }
        self.allTabs = allTabs
        // Posts alone until the other sources answer (#742): a source shows
        // up only with something in it.
        let shown = allTabs.filter { $0 == .format(.activity) }
        self.initialTabs = shown
        let savesPosts = viewModel.bookmarks != nil
        // A tab's page is built the first time it is shown (#2125).
        // The Channels page draws its model (#2232); "Create a Channel" asks
        // the model, which this screen answers with the sheet.
        var makeChannelsPage: (() -> any PostGridPage)?
        if let channels {
            makeChannelsPage = { [imagePipeline] () -> any PostGridPage in
                let page = ProfileChannelsPage(model: channels, pipeline: imagePipeline)
                // The model holds no page: the page may keep it.
                page.onCreate = { channels.requestCreation() }
                return page
            }
        }
        let pager = ProfileGalleryPagerView(
            tabs: allTabs, shown: shown, makeChannelsPage: makeChannelsPage, presence: presence
        ) { style in
            makeGridPage(style, savesPosts)
        }
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
        accountSwitcher.subscribe()
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
                // Follow ⇄ the bell is the tray's morph (#2302): the
                // optimistic flip and its rollback both animate it.
                self.applyHeaderAction()
                self.applyRelationMark()
                // Whose posts these are just changed: on the viewer's own
                // profile the rows gain Edit and Delete, drawn now rather
                // than once each row is configured again.
                self.galleryPager.refreshAuthorMenus()
                // The relationship usually resolves while the push/present
                // is still animating; bind the bar inside the transition so
                // the toolbar composes during the animation, not after it.
                self.alongsideTransition { $0.applyNavigationState(animated: $1) }
                self.noteLandingMilestone()
            }
        }
        viewModel.onRelationshipSettled = { [weak self] in
            guard let self else { return }
            // The button moves before the read counts as settled, so the
            // tray could still presume someone else: a bell the answer rules
            // out (the viewer's own handle, #800) goes now, and one a lookup
            // has just resolved becomes usable.
            self.applyHeaderAction()
            self.noteLandingMilestone()
        }
        headerView.onPicturesSettled = { [weak self] in self?.noteLandingMilestone() }
        viewModel.onMapPinButtonChange = { [weak self] _ in
            HeroScreenCost.measure("landing.mapPin") {
                // The rails' rows keep the menu open (`.keepsMenuPresented`):
                // their checkmarks follow in place.
                self?.relationActions.refreshVisibleMapRows()
                self?.noteLandingMilestone()
            }
        }
        viewModel.onMuteScopesChange = { [weak self] _ in
            // The bell changes at once — on the tap, and back on a refusal or
            // an Undo — beside its toast, never under it (#2143).
            self?.applyHeaderAction()
        }
        // The tray's bell opens the scoped Mute menu (#689, #2302).
        headerView.setBellMenu(relationActions.makeMuteMenu())
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
        relationActions.configureMoreMenu()
        viewModel.onActionResult = { [weak self] result in
            self?.relationActions.render(result)
        }
        // Deleting a post, muting, restricting: done at once on screen, with
        // Undo in the toast; sent when its countdown runs out (#957).
        viewModel.onUndoable = { [weak self] action in
            self?.relationActions.presentUndoable(action)
        }
        viewModel.onDismissRequested = { [weak self] in
            self?.relationActions.leaveAfterBlock()
        }
        viewModel.onLoadSettled = { [weak self] in
            HeroScreenCost.measure("landing.settled") {
                self?.accountSwitcher.isSwitchingProfile = false
                // A refresh that brought nothing new publishes no phase, so
                // the spinner stops here — where every load ends, however it
                // ended.
                self?.pullIndicator.endRefreshing()
            }
        }
        // A gallery that landed before this screen bound: its tabs now.
        if let landed = viewModel.publishedGallery {
            lastGallerySnapshot = landed
            tabPages.showTabs(for: landed)
        }
        viewModel.onGalleryChange = { [weak self] snapshot in
            self?.lastGallerySnapshot = snapshot
            self?.historySelectMode.historyChanged()
            self?.tabPages.showTabs(for: snapshot)
            HeroScreenCost.measure("landing.gallery") { self?.galleryPager.render(snapshot) }
            // The media gallery "View all" pushed, if it is up, grows with
            // the pages as they land (#631).
            self?.postOpening.mediaGallery?.render(snapshot.media)
            self?.noteLandingMilestone()
            #if DEBUG
            self?.auditPostMenu(snapshot)
            #endif
        }
        tabPages.bindChannels()
        galleryPager.onItemTapped = { [weak self] post, stream in
            self?.openGalleryPost(post, stream: stream, showingComments: false)
        }
        // History holds still while its post is up (#2170, the owner).
        galleryPager.onHistoryPostOpening = { [weak self] in
            guard let self else { return }
            viewModel.holdHistory()
            isShowingHistoryPost = true
        }
        // A card's comment chip: the same open, arriving with the thread up.
        galleryPager.onItemCommentsTapped = { [weak self] post, stream in
            self?.openGalleryPost(post, stream: stream, showingComments: true)
        }
        galleryPager.onAuthorTapped = { [weak self] post in
            self?.viewModel.galleryAuthorTapped(post)
        }
        // A History row's author: tap → the card, hold → the profile (#2145).
        galleryPager.onAuthorCardTapped = { [weak self] post in
            self?.viewModel.galleryAuthorCardTapped(post)
        }
        // A History row's VoiceOver action (#2170): the menu's own row.
        galleryPager.onRemoveFromHistory = { [weak self] post in
            self?.viewModel.removeFromHistory(post.id)
        }
        galleryPager.onViewAllTapped = { [weak self] in self?.pushMediaGallery() }
        galleryPager.authorMenuActions = { [weak self] context, tab in
            guard let self else { return [] }
            var actions = relationActions.galleryMenuActions(for: context)
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
            self.tabPages.adoptTab(tab)
            if let index = self.tabs.firstIndex(of: tab) {
                self.tabPages.mirrorSelection(to: index)
            }
        }
        tabPages.configureFilterTray()
        // Mirror the (possibly stub-seeded) relationship into the header's
        // tray, so Message visibility agrees with the toolbar from the start.
        applyHeaderAction()
        applyRelationMark()
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
        // A guest is known only once a gate is up the chain (#2014): their
        // tray has no bell (#2302).
        applyRelationMark()
        applyHeaderAction()
        Task { [weak self] in await self?.viewModel.refreshShareToken() }
        // Back from a channel's thread or the new channel's sheet (#2232):
        // a join there, or a channel just created, shows on the rows. Only
        // once they were read — the first read waits for the profile.
        if channels?.phase == .loaded { channels?.reload() }
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
        // Pushed in, or a plain screen popping off this one (#1914): the
        // gallery's clips start once half of the screen is on display, on the
        // transition's own frames. Every other appearance starts them from
        // `viewDidAppear`, as before.
        _ = viewportShare.screenWillAppear(self)
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
        if !hasLoggedFirstFrame, LaunchArgument.profileFirstFrameLog.isPassed() {
            hasLoggedFirstFrame = true
            print("[profile-first-frame] settled=\(isSettled) "
                  + "redacted=\(debugIsHeaderRedacted) follow=\(debugFollowTitle ?? (debugMuteBell != nil ? "bell" : "placeholder")) "
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
        // Leaving the profile ends History's select mode.
        setSelectingHistory(false, restoresFoot: false)
        // The band comes down; the toolbar is the stack's, put away unless the
        // screen taking over brings items of its own (the relations screen,
        // the feed).
        selector.hide(leaving: self, animated: animated, alongside: transitionCoordinator)
        // The banner too (#1399): the hero page plays it on while the screen
        // leaves, up to half (`viewportAllowsBanner`).
        //
        // ⚠️ NOT AT THE TRANSITION'S FIRST FRAME (#1914, the owner
        // 2026-10-31): the gallery's clips play while this screen holds half
        // the viewport — the rule of every screen (`ViewportShare`). Its own
        // pop pauses them once it is half off, a screen pushed over it once it
        // covers half, and a drag abandoned before half never pauses them.
        if viewportShare.screenWillDisappear(self) == .flight {
            // A post opened from a tile: its own player is what should be
            // heard, at once.
            galleryPager.setAutoplayActive(false)
        }
    }

    /// The share of this screen on screen (#1914): its gallery's clips play
    /// at half and above.
    private lazy var viewportShare: ViewportShare = {
        let share = ViewportShare(host: view)
        share.onPlaysChange = { [weak self] plays in
            guard let self else { return }
            galleryPager.setAutoplayActive(plays)
            // The banner follows a transition's half. With none to follow
            // the screen is gone at once, and the banner's own rule stops it
            // then (#1399) — stopped and restarted here, it lost its player.
            if plays || transitionCoordinator != nil { viewportAllowsBanner = plays }
        }
        return share
    }()

    /// The share now, for tests.
    var debugViewportShare: ViewportShare { viewportShare }

    /// The post has finished covering this screen, so the tapped tile can be
    /// brought clear of the chrome without anyone seeing it move.
    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        // Not `viewWillDisappear`: that fires as the transition begins, while
        // the grid is still visible behind an expanding hero card.
        galleryPager.applyPendingReveal()
        // What the cards staked while the screen was up is final now.
        staking?.endSession()
        // Gone for anything but History's own post — another tab, a screen
        // pushed over it: the viewer left History (#2170).
        if !isShowingHistoryPost { viewModel.releaseHistory() }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // Back from History's post (not from a close abandoned half-way,
        // which never appears): the next leave is a real one.
        isShowingHistoryPost = false
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
        viewportShare.report(1)
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
        debugHooks.armOnce()
        #endif
    }

    /// Opens the followers / following lists on the tapped counter's tab.
    ///
    /// Pushed onto this screen's own stack rather than routed: the destination
    /// is another Profile surface, and `AppRoute` exists for *cross-feature*
    /// navigation (the rows inside it do route — each one opens someone else's
    /// profile). Gated on a loaded profile, because the subject it hands over
    /// carries the privacy state.
    func pushRelationships(_ direction: RelationshipDirection) {
        guard let makeRelationshipsViewController,
              let subject = viewModel.relationshipsSubject
        else { return }
        navigationController?.pushViewController(
            makeRelationshipsViewController(subject, direction), animated: true
        )
    }

    func pushEditProfile() {
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

    // MARK: - Relation actions

    /// The header's relation row, the menus and the actions' outcomes
    /// (`ProfileRelationActions`, #2522).
    private(set) lazy var relationActions = ProfileRelationActions(host: self)
    var actionAnchor: UIView { headerView.moreButtonAnchor }
    var blockToastSource: UIViewController { navigationController ?? self }
    private func applyHeaderAction() { relationActions.applyHeaderAction() }
    private func applyRelationMark() { relationActions.applyRelationMark() }
    func presentShareSheet() { relationActions.presentShareSheet() }
    func copyProfileLink() { relationActions.copyProfileLink() }
    func moreMenuElements() -> [UIMenuElement] { relationActions.moreMenuElements() }
    #if DEBUG
    var debugMuteToastsShown: Int { relationActions.debugMuteToastsShown }
    var debugUndoToastsShown: Int { relationActions.debugUndoToastsShown }
    var debugLastUndoToast: ToastView? { relationActions.debugLastUndoToast }
    #endif

    /// The keys the router's repeat filter asks about (#800).
    var profileRouteKeys: Set<ProfileRouteKey> { viewModel.profileRouteKeys }

    // MARK: - Follow in the corner (#2248)

    static let followItemID = "profile.follow"
    static let requestedItemID = "profile.follow-requested"

    /// The item the bar's corner wears for the relation, or nil: Follow or
    /// Requested only once the tray has scrolled away (the owner,
    /// 2026-11-10), where the identity pill came in before (#1451) — so the
    /// page never shows the tray's Follow and the bar's at once.
    ///
    /// | Relation        | Corner      |
    /// |-----------------|-------------|
    /// | not followed    | Follow      |
    /// | requested       | Requested   |
    /// | followed        | nothing     |
    /// | blocked, nobody, the viewer's own, not read yet | nothing |
    ///
    /// ⚠️ NEVER THE BELL (#2302, the owner 2026-11-11): once followed, the
    /// header's Follow becomes the bell, and the corner stays empty, scrolled
    /// or not. A follow from the bar's Follow takes it out, animated
    /// (`updateActionBarItem`).
    ///
    /// A guest reads as not followed, so Follow — behind the member gate,
    /// as the tray's Follow is (`headerView.onFollowTapped`).
    private var cornerItem: UIBarButtonItem? {
        guard showsRelationshipItem else { return nil }
        switch followButtonState {
        case .follow: return followBarItem
        case .requested: return requestedBarItem
        default: return nil
        }
    }

    /// Whether Follow / Requested may stand in the corner now: someone
    /// else's profile, read, not blocked, its tray out of sight.
    private var showsRelationshipItem: Bool {
        guard isTrayScrolledAway, !viewModel.namesNoOne, !viewModel.isBlocked else { return false }
        guard !viewModel.isOwnProfile, !identityStubIsSelf, makeEditViewController == nil else { return false }
        return followButtonState == .follow || followButtonState == .requested
    }

    /// Whether the bar wears Follow or Requested right now.
    private var isShowingRelationshipItem: Bool {
        ownTrailingBarItems.contains { $0 === followBarItem || $0 === requestedBarItem }
    }

    /// Follow, or Requested: a titled native item (the bar contract, #1679)
    /// whose tap is the tray's own — `headerView.onFollowTapped`: the member
    /// gate for a guest, the optimistic flip, its haptic, a request on a
    /// private profile and its withdrawal on Requested. One path, so the bar
    /// and the tray can never disagree on what a tap did.
    ///
    /// Follow wears the bar's `.prominent` style, in the brand's primary;
    /// Requested stays plain (#2268, the owner 2026-11-10 — the colour only
    /// while it reads "Follow").
    private func makeRelationshipBarItem(requested: Bool) -> UIBarButtonItem {
        let item = BarItems.title(
            id: requested ? Self.requestedItemID : Self.followItemID,
            title: requested ? "Requested" : "Follow",
            prominent: !requested
        ) { [weak self] in self?.headerView.onFollowTapped?() }
        if requested { item.accessibilityHint = "Withdraws your follow request." }
        return item
    }

    #if DEBUG
    /// Stands in for the scroll: the tray out of sight, or back.
    /// The scroll's own path: the header placed for `travelled`, the tray's
    /// visibility decided from it.
    func debugApplyHeaderOffset(_ travelled: CGFloat) { applyHeaderOffsetNow(travelled) }
    func debugSetTrayScrolledAway(_ away: Bool) {
        isTrayScrolledAway = away
        updateActionBarItem(followButtonState)
        applyBarTitle()
    }
    func debugSetHandlePassage(_ passage: CGFloat) { barTitle.debugSetHandlePassage(passage) }
    var debugBarTitleOpacity: CGFloat { barTitle.debugBarTitleOpacity }
    /// The bar's Follow or Requested, if it shows one (#2248).
    var debugBarRelationshipItem: UIBarButtonItem? {
        ownTrailingBarItems.first { $0 === followBarItem || $0 === requestedBarItem }
    }
    /// Every write of the bar's trailing group, in order: whether it was
    /// animated, so UIKit could morph it (#1903). A test reads how Follow
    /// left.
    var debugBarWrites: [Bool] = []
    /// The bell, if the header's row shows it (#2302).
    var debugMuteBell: AppButton? { headerView.debugBell }
    /// What picking the bell menu's `scope` does. Tests.
    func debugToggleMute(_ scope: MuteScope) { viewModel.toggleMute(scope) }
    func debugMuteMenuElements() -> [UIMenuElement] { relationActions.muteMenuElements() }
    func debugMoreMenuElements() -> [UIMenuElement] { moreMenuElements() }
    /// The map pin's rows, for `-profile-map-pin-audit` (+QA).
    func debugMapFavoriteMenuActions() -> [UIAction] { relationActions.mapFavoriteMenuActions() }
    /// A gallery card's "..." rows, for `-post-menu-audit` (+QA).
    func debugGalleryMenuActions(
        for context: PostGridAuthorMenuContext
    ) -> [PostCardMenuAction] {
        relationActions.galleryMenuActions(for: context)
    }
    #endif

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

        accountSwitcher.configureNameSwitcher()
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

    /// The leading group: the tab root's bell. A pushed profile leads with
    /// its back button and its @handle, a native title (#2248) — the
    /// identity pill that came in beside the chevron is gone (#1590's
    /// leading placement with it).
    private var leadingItems: [UIBarButtonItem] {
        [leadingAccessoryItem].compactMap { $0 }
    }

    /// History's day in the bar (#1344): the app's one section contract
    /// (#1573) — it mints the item (one per day, each with its own
    /// identifier, so UIKit morphs between them), places it, and never
    /// mid-push. A tap: the day's first post under the bar.
    ///
    /// - Someone else's profile: innermost of the TRAILING group (#1590) —
    ///   the leading side is the chevron and the @handle (#2248) — through
    ///   `setOwnTrailingBarItems`.
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
    var dayLeads: Bool { onLogout != nil }

    /// Names `section` innermost of the trailing group, or takes the name
    /// away. No day over a page for no one (#1406): its gallery is gone.
    private func applyPinnedSection(_ section: PostGridPinnedSection?) {
        pinnedSection = section
        let shown = viewModel.namesNoOne ? nil : section
        sectionBinding.show(pinned: shown.map { ($0.index, .init(id: $0.title, title: $0.title, count: $0.count)) })
    }

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

    func pushSettings() {
        guard let settingsViewController = makeSettingsViewController?() else { return }
        navigationController?.pushViewController(settingsViewController, animated: true)
    }

    /// The single application point for everything the navigation bar shows —
    /// the @handle as a leading title on a pushed profile (#2248), the shell's
    /// items, the bell or Follow in the corner. Idempotent, driven from three
    /// places: viewDidLoad (initial composition), viewWillAppear (synchronous
    /// pre-transition bind), and the async data callbacks (via
    /// `alongsideTransition`).
    func applyNavigationState(animated: Bool = false) {
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
        //   tab root  [bell][day] … [coins][gear | Select | Done]
        //             (History only: Select once the tray has scrolled away,
        //             Done while selecting, wherever the scroll — #2307)
        //   pushed    [‹ @handle] … [day][coins][Follow | Requested | bell]
        //             (Follow / Requested once the tray has scrolled away,
        //             the bell whenever followed, the day on History — #2248)
        // Written only when it changed — the same "say nothing" rule as the
        // trailing run below, for the same torn-capsule reason.
        let leading = leadingItems
        if dayLeads {
            // The contract writes the group, the day after the bell (#1642):
            // at once, as below, and only if it changed.
            sectionBinding.leadingPrefix = leading
            sectionBinding.placeNow()
        } else if !(navigationItem.leftBarButtonItems ?? []).elementsEqual(leading, by: ===) {
            navigationItem.leftBarButtonItems = leading
        }
        // ⚠️ **WITHOUT THIS THE ITEM REPLACES THE BACK BUTTON**, and UIKit
        // disables the interactive pop along with it, silently. Harmless on the
        // tab root, which has no back button to supplement.
        navigationItem.leftItemsSupplementBackButton = true

        applyBarTitle()
        updateActionBarItem(followButtonState, animated: animated)
    }

    // MARK: - The @handle in the bar (#2248)

    /// The bar's @handle title, scrubbed on the scroll (`ProfileBarTitle`,
    /// #2522).
    private(set) lazy var barTitle = ProfileBarTitle(host: self)
    var namesNoOne: Bool { viewModel.namesNoOne }
    func setSoftTopEdge(_ soft: Bool) { heroPager.setSoftTopEdge(soft) }
    private func applyBarTitle() { barTitle.applyBarTitle() }

    /// Recomposes the bar once no transition runs, without animation — for an
    /// item that leaves mid-transition (#800, #756).
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

    /// Composes the trailing group per the current state: the own profile's
    /// gear (History's Select or Done in its place, #2307), the corner item
    /// (`cornerItem` — Follow / Requested once the tray has scrolled away,
    /// #2248; never the bell, #2302), the shell's balance, and
    /// History's day. Nothing relational until the relationship is known.
    /// Native items only (the bar contract, #1679): iOS 26 wraps each in the
    /// bar's own Liquid Glass capsule, and a glass-configured custom button
    /// would stack a second material on top of it.
    private func updateActionBarItem(_ state: ProfileViewModel.FollowButton, animated: Bool = false) {
        // Edit is no longer a bar item — it lives in the header tray beside the
        // avatar (see `ProfileHeaderView.configureAction`), so own-profile keeps
        // only its account overflow menu here.
        // `.hidden` yields no item at all. It used to install a bare custom
        // view as a placeholder pill, which was both unreachable — every path
        // into `followButtonState` sets a concrete state, the view model never
        // assigns `.hidden`, and the audit only ever logs `follow`/`following`
        // — and the one thing in this slot that UIKit could not animate across
        // a transition. An absent item is the honest native answer for "no
        // relationship applies".
        // Follow / the bell lives in the header's tray beside Message — see
        // `ProfileHeaderView.configureAction`. The bar takes Follow (or
        // Requested) over only once that tray has scrolled out of sight
        // (#2248), and never the bell (#2302): once followed, the corner is
        // empty. `state` still arrives, because a rebuild is keyed on it and
        // the guard below decides whether anything actually changed.
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
        // A page for no one (#800, #1406) acts on no one: no relationship,
        // no balance. A pushed one keeps only its back button;
        // the viewer's own tab root keeps the gear and the switcher, its only
        // way to settings and to another profile.
        let namesNoOne = viewModel.namesNoOne
        // The own profile's corner: the gear — or, on History once the tray
        // has scrolled away, Select in its place, and Done while selecting
        // wherever the scroll is (#2307, the owner 2026-11-11). Each its own
        // item under its own identifier, so UIKit morphs the gear into Select
        // and back (R3), on the trigger the handle and the blur use (#2268).
        let historyItem = historySelectBarItem
        if let historyItem {
            items.append(historyItem)
        } else if let settingsItem {
            items.append(settingsItem)
        }
        // The corner, someone else's profile only: `[0]`, as the gear is on
        // your own. Follow or Requested, once the tray has scrolled away
        // (#2248, where the identity pill came in before, #1451) —
        // `[coins][Follow]`, then `[coins]` once followed: the bell is the
        // header's now (#2302). Each its own item under its own identifier,
        // so UIKit morphs one into the other (R3).
        let corner = namesNoOne ? nil : cornerItem
        if let corner { items.append(corner) }
        // The shell's accessory next: the gear keeps the corner and the
        // balance sits inboard — the Explore header's arrangement ([coins]
        // [search]). On a pushed profile, which has neither the gear nor the
        // switcher, the balance is the corner. Fixed spaces keep each its own
        // bubble — adjacent items share one glass capsule.
        // ⚠️ THE BALANCE IS NEVER REPLACED (#2307): History's Select / Done
        // took its place until then (#2188); it stands in the gear's now, and
        // the balance keeps its own on every tab.
        if let trailingAccessoryItem, !namesNoOne {
            if corner != nil {
                items.append(cornerSpacer)
            } else if historyItem != nil {
                items.append(historySelectSpacer)
            }
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
        // ⚠️ THE CORNER CHANGING waits for rest, then comes in animated
        // (#2248): Follow added mid-push would pop in unanimated at the end
        // (#756) — and so would Follow taken away.
        let cornerArrives = corner.map { item in !ownTrailingBarItems.contains { $0 === item } } ?? false
        let relationshipLeaves = isShowingRelationshipItem && corner !== followBarItem && corner !== requestedBarItem
        // So does the own profile's corner changing hands (#2307) — Done
        // leaving as the screen does (`viewWillDisappear`), Select or the gear
        // coming back: a write mid-push lands unanimated at its end (#756).
        // On this screen's own coordinator, one turn after its completion; a
        // coordinator already past its animations takes the write now.
        let historySlotChanges = dayLeads && shownHistoryBarItem !== historyItem
        if historySlotChanges, let coordinator = transitionCoordinator,
           coordinator.animate(alongsideTransition: nil, completion: { [weak self] _ in
               DispatchQueue.main.async { [weak self] in
                   guard let self else { return }
                   updateActionBarItem(followButtonState, animated: view.window != nil)
               }
           }) {
            return
        }
        if cornerArrives || relationshipLeaves, transitionCoordinator != nil {
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
        if LaunchArgument.profileNavbarAudit.isPassed() {
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
        // composes the group with the day and writes it.
        #if DEBUG
        debugBarWrites.append(animated && UIView.areAnimationsEnabled)
        #endif
        if dayLeads {
            // The day is leading here (#1642): the trailing group is all ours.
            setOwnTrailingBarItems(items, animated: animated)
        } else {
            sectionBinding.trailingItems = items
            sectionBinding.placeNow(animated: animated)
        }
    }

    /// The tabs, their selector and the Channels tab (`ProfileTabPages`, #2522).
    private(set) lazy var tabPages = ProfileTabPages(host: self, tabs: initialTabs)
    var tabs: [ProfileTab] { tabPages.tabs }
    var shownTab: ProfileTab? { tabPages.shownTab }

    // MARK: - History's select mode (the owner, 2026-11-08)

    /// History's select mode (`ProfileHistorySelection`, #2522).
    private(set) lazy var historySelectMode = ProfileHistorySelection(host: self)
    var isSelectingHistory: Bool { historySelectMode.isSelectingHistory }
    private var historySelectBarItem: UIBarButtonItem? { historySelectMode.historySelectBarItem }
    private var shownHistoryBarItem: UIBarButtonItem? { historySelectMode.shownHistoryBarItem }
    func setSelectingHistory(_ selecting: Bool, restoresFoot: Bool = true) {
        historySelectMode.setSelectingHistory(selecting, restoresFoot: restoresFoot)
    }

    #if DEBUG
    var debugHistoryPage: (any PostGridPage)? { galleryPager.builtPage(for: .history) }
    var debugAllowsPaging: Bool { galleryPager.allowsPaging }
    var debugHistoryRemoveTitle: String? { historySelectMode.debugHistoryRemoveTitle }
    var debugHistoryRemoveEnabled: Bool { historySelectMode.debugHistoryRemoveEnabled }
    func debugTapHistoryRemove() { historySelectMode.debugTapHistoryRemove() }
    #endif

    /// A post opened from History is covering the screen: the screen is
    /// gone, but the viewer has not left History (#2170). Cleared once the
    /// screen is back.
    private var isShowingHistoryPost = false

    func selectTab(at index: Int) { tabPages.selectTab(at: index) }

    static func rememberedTabs(
        _ tabs: [ProfileTab], in snapshot: ProfileViewModel.GallerySnapshot,
        screen: String?, presence: SectionPresenceStore
    ) -> [ProfileTab] {
        ProfileTabPages.rememberedTabs(tabs, in: snapshot, screen: screen, presence: presence)
    }
    static func shownTabs(
        _ all: [ProfileTab], in snapshot: ProfileViewModel.GallerySnapshot, isOwnProfile: Bool,
        hasChannels: Bool = false
    ) -> [ProfileTab] {
        ProfileTabPages.shownTabs(all, in: snapshot, isOwnProfile: isOwnProfile, hasChannels: hasChannels)
    }
    static func withPostsBesideChannels(_ shown: [ProfileTab]) -> [ProfileTab] {
        ProfileTabPages.withPostsBesideChannels(shown)
    }

    // MARK: - The hero page's contract

    /// A finger's pull reached the threshold (#2235), or a page asking.
    override func heroPageRefresh() {
        viewModel.refresh()
        // The channels too (#2232): a pull reads the whole profile again.
        channels?.reload()
        // History too, even held (#2170, the owner).
        viewModel.refreshHistory()
    }

    /// A profile with no gallery (a page for no one) needs no air under it.
    override var heroPageBottomBreathingRoom: CGFloat { viewModel.hasGallery ? 8 : 0 }

    /// Once the tray has scrolled under the bar, the bar's corner carries the
    /// profile's Follow or Requested (#2248) — and gives it back to the tray
    /// on the way down. On the viewer's own History, the gear becomes Select
    /// on the same frame (#2307).
    ///
    /// The bar's @handle follows the header's @handle line, step by step
    /// (#2334): a slow scroll brings it slowly, and a stop half way leaves
    /// it half way.
    override func heroPageHeaderDidMove(travelled: CGFloat) {
        let passageChanged = barTitle.headerDidMove(travelled: travelled)
        let trayGone = isActionRowUnderBar(travelled: travelled)
        guard trayGone != isTrayScrolledAway else {
            // Only the title moves: no item, no blur.
            if passageChanged { applyBarTitle() }
            return
        }
        isTrayScrolledAway = trayGone
        // The corner item and the blur on the same frame (#2268); the
        // handle, already whole by now, stays so.
        updateActionBarItem(followButtonState, animated: view.window != nil && transitionCoordinator == nil)
        applyBarTitle()
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
            headerView.render(phase, profileKnown: viewModel.profile != nil, switching: accountSwitcher.isSwitchingProfile, animated: false)
            if viewModel.hasGallery {
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
            // Instagram-style: the @handle is the screen's title (the header
            // shows the bold display name). "Profile" only until first load.
            // Content usually lands mid-push; rebind inside the transition
            // so the bar text doesn't snap in after the animation settles.
            currentHandle = model.handle
            // Whose channels to list, once the profile is known (#2232) —
            // again after an account switch, never on a mere re-render.
            if let channels, channels.owner != model.id { channels.load(owner: model.id) }
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
                phase, profileKnown: true, switching: accountSwitcher.isSwitchingProfile, animated: view.window != nil
            )
            updateBannerVideo()

        case .failed(let message):
            pullIndicator.endRefreshing()
            // Never leave the previous profile held over an error.
            galleryPager.isHidden = true
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
        guard LaunchArgument.profileFirstFrameLog.isPassed() else { return }
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

extension ProfileViewController {
    func pushMediaGallery() { postOpening.pushMediaGallery() }

    func openGalleryPost(
        _ post: GalleryPost, stream: [GalleryPost], showingComments: Bool,
        from surface: (any PostGridPage)? = nil,
        presenter: UIViewController? = nil,
        format: GalleryFilter.Format = .activity
    ) {
        postOpening.openGalleryPost(
            post, stream: stream, showingComments: showingComments, from: surface, presenter: presenter, format: format
        )
    }
}

// MARK: - Tab re-tap (#1309)

extension ProfileViewController: TabReselectScrolling {
    /// Back to the PROFILE's top — the identity and its tray at rest — not
    /// merely the active tab's first row.
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

// MARK: - How it is left (#1144)

extension ProfileViewController: StackScreen {
    var leaving: ScreenLeaving { .nativeBack }
}

#if DEBUG
extension ProfileViewController: ProfileDebugHooksHost {}
#endif

extension ProfileViewController: ProfileRelationActionsHost {}

extension ProfileViewController: ProfileTabPagesHost {}

extension ProfileViewController: ProfileHistorySelectionHost {}

extension ProfileViewController: ProfilePostOpeningHost {}

extension ProfileViewController: ProfileAccountSwitcherHost {}

extension ProfileViewController: ProfileBarTitleHost {}
