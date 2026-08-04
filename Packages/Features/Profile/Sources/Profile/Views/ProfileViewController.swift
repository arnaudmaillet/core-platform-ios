import MediaCore
import CoreModels
import ProfileInterface
import CoreNavigation
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

    private let scrollView = UIScrollView()
    /// Retained for the share sheet, which builds its own QR card (and a
    /// throwaway one to rasterize) and needs the same avatar cache.
    private let imagePipeline: ImagePipeline
    /// Supplies the share sheet's quick-send row; nil hides it.
    private let shareTargeting: (any ProfileShareTargeting)?
    private let headerView: ProfileHeaderView
    private let galleryPager: ProfileGalleryPagerView
    /// The gallery's format selector — the SAME `PagedTabBar` For You and
    /// Messages wear, so a viewer meets one selector in three places rather
    /// than three selectors doing one job.
    ///
    /// It starts inline, under the identity block where it belongs to the
    /// profile, and docks into the navigation bar's title slot as the identity
    /// scrolls away — see `updateBarDocking`. That is why it is built in the
    /// `.navigationTitle` style even though it spends most of its life inline:
    /// the docked size is the constrained one, and a bar that only fits in the
    /// place it is not going is no use.
    private let categoryBar = PagedTabBar(
        titles: ["Activity", "Gallery", "Short"], style: .navigationTitle
    )
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
    private let refreshControl = UIRefreshControl()
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
        /// The height the selector's slot holds in the scrolling column,
        /// whether or not the selector is in it.
        static let selectorSlotHeight: CGFloat = 52
        /// How far past the navigation bar the slot has to travel before the
        /// selector docks, and how far back before it returns.
        ///
        /// ⚠️ Hysteresis, not a threshold. One line would flap: docking removes
        /// the bar from the slot, which is a layout change, which arrives as
        /// another scroll callback — and a viewer resting a finger exactly on
        /// the line would watch it flicker between the two homes.
        static let dockingHysteresis: CGFloat = 12
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
        galleryPager = ProfileGalleryPagerView(imagePipeline: imagePipeline)
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
        galleryPager.onItemTapped = { [weak self] post in
            self?.viewModel.galleryItemTapped(post.id)
        }
        // Swipe ↔ tabs: a settled swipe adopts the format and mirrors the
        // tabs; a tab tap records the format and pages.
        galleryPager.onPageSettled = { [weak self] format in
            guard let self else { return }
            self.viewModel.setGalleryFormat(format)
            if let index = ProfileGalleryPagerView.pageOrder.firstIndex(of: format) {
                self.categoryBar.select(index)
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
        // Re-bind the bar synchronously BEFORE the transition animates: any
        // state that resolved since viewDidLoad (fast mock loads, cached
        // profiles, returning from a pushed child) is fully populated here,
        // so the title and Follow item ride the push natively instead of
        // popping in after it.
        applyNavigationState()
        presentFilterToolbar()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        concealFilterToolbar()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
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
        #if DEBUG
        // Dev convenience: `-profile-overscroll` parks the scroll view in the
        // pulled-down region (no touch injection in the sim), so the banner's
        // stretch-over-overscroll behavior can be screenshotted.
        if ProcessInfo.processInfo.arguments.contains("-profile-overscroll") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                self?.scrollView.setContentOffset(CGPoint(x: 0, y: -140), animated: true)
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
        if scrollView.contentInset.bottom != bottom {
            scrollView.contentInset.bottom = bottom
            scrollView.verticalScrollIndicatorInsets.bottom = bottom
        }
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
        if navigationItem.leftBarButtonItem !== switcherItem {
            navigationItem.leftBarButtonItem = switcherItem
        }

        // Relationship action for other users; the gear for own profile (where
        // `action` is nil).
        var items: [UIBarButtonItem] = []
        if let action { items.append(action) }
        if let settingsItem { items.append(settingsItem) }
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
        scrollView.alwaysBounceVertical = true
        // The header's banner must start at y = 0 of the screen, so the scroll
        // view must not push content below the (transparent) navigation bar;
        // the header re-adds the chrome height for its overlay content via
        // `chromeTopInset` (see viewSafeAreaInsetsDidChange).
        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.delegate = self
        scrollView.pin(to: view)

        refreshControl.addAction(UIAction { [weak self] _ in self?.viewModel.refresh() }, for: .valueChanged)
        // The pull-down region is no longer bare background — the banner
        // stretches over it (see anchorBanner below) — so the spinner must
        // render above the media, in a color that survives it (the banner's
        // top scrim backs it up).
        refreshControl.tintColor = .white
        refreshControl.layer.zPosition = 1
        scrollView.refreshControl = refreshControl

        let content = scrollView.contentLayoutGuide
        let frame = scrollView.frameLayoutGuide
        headerView.constrain(in: scrollView) { _ in
            headerView.topAnchor.constraint(equalTo: content.topAnchor)
            headerView.leadingAnchor.constraint(equalTo: content.leadingAnchor)
            headerView.trailingAnchor.constraint(equalTo: content.trailingAnchor)
            headerView.widthAnchor.constraint(equalTo: frame.widthAnchor)
        }
        // The selector's slot sits between the identity block and the gallery
        // it filters — the one place on this screen where "what you are looking
        // at" changes hands.
        inlineBarSlot.isHidden = !viewModel.hasGallery
        inlineBarSlot.constrain(in: scrollView) { _ in
            inlineBarSlot.topAnchor.constraint(equalTo: headerView.bottomAnchor, constant: 12)
            inlineBarSlot.leadingAnchor.constraint(equalTo: content.leadingAnchor)
            inlineBarSlot.trailingAnchor.constraint(equalTo: content.trailingAnchor)
            inlineBarSlot.widthAnchor.constraint(equalTo: frame.widthAnchor)
            inlineBarSlot.heightAnchor.constraint(
                equalToConstant: viewModel.hasGallery ? Metrics.selectorSlotHeight : 0
            )
        }

        // The gallery pager continues the header's column; its height tracks
        // the active page, so together they define the content height.
        galleryPager.isHidden = !viewModel.hasGallery
        galleryPager.constrain(in: scrollView) { _ in
            galleryPager.topAnchor.constraint(equalTo: inlineBarSlot.bottomAnchor, constant: 4)
            galleryPager.leadingAnchor.constraint(equalTo: content.leadingAnchor)
            galleryPager.trailingAnchor.constraint(equalTo: content.trailingAnchor)
            galleryPager.widthAnchor.constraint(equalTo: frame.widthAnchor)
            galleryPager.bottomAnchor.constraint(equalTo: content.bottomAnchor)
        }

        // Stretchy banner: on downward overscroll the banner must keep
        // covering the screen from the very top instead of riding down with
        // the header and exposing the background.
        headerView.anchorBanner(toViewportTop: frame.topAnchor)

        let viewportFill = content.heightAnchor.constraint(greaterThanOrEqualTo: frame.heightAnchor)
        viewportFill.priority = UILayoutPriority(800)
        skeletonViewportFill = viewportFill

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

        categoryBar.addAction(
            UIAction { [weak self] _ in
                guard let self else { return }
                let format = ProfileGalleryPagerView.pageOrder[categoryBar.selectedIndex]
                viewModel.setGalleryFormat(format)
                galleryPager.setActivePage(format, animated: true)
            },
            for: .valueChanged
        )
        // The lens tracks the finger, exactly as it does on the other two
        // screens that wear this bar — the pager reports a fractional position
        // every frame and the capsule interpolates against it.
        galleryPager.onProgress = { [weak self] progress in self?.categoryBar.setProgress(progress) }
        // The capsule is grabbable: dragging it scrubs the pages under the
        // finger and releasing commits to whichever one it landed nearest. The
        // same two lines the other two screens that wear this bar already have.
        categoryBar.onScrub = { [weak self] progress in self?.galleryPager.scrub(to: progress) }
        categoryBar.onScrubEnd = { [weak self] velocity in
            self?.galleryPager.settleAfterScrub(velocityInPages: velocity)
        }

        // Land on the user's global preference: tab selection and pager page
        // adopt the (possibly stored) filter before first layout, so the
        // screen OPENS there — no visible jump.
        let format = viewModel.galleryFilter.format
        if let index = ProfileGalleryPagerView.pageOrder.firstIndex(of: format) {
            categoryBar.select(index)
        }
        galleryPager.setActivePage(format, animated: false)

        undockBar()

        placeSourceTray()
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

    /// Puts the selector in the navigation bar's title slot.
    ///
    /// ⚠️ **The bar IS the title view — it is not put inside one.** It was
    /// wrapped in a container at first, so the container could hold a stable
    /// size for the bar cache. That container was positioned by hand, its frame
    /// never grew to the bar's, and a `UIView` clips its own hit-testing to its
    /// bounds — so most of the docked capsule took no touches at all and the
    /// drag gesture appeared dead. Handing UIKit the bar directly is also what
    /// the other two screens do; there is no wrapper on either of them.
    ///
    /// A title view is positioned by FRAME, so autoresizing has to come back on
    /// for the trip — the inline slot lays it out with constraints, and a view
    /// cannot be laid out both ways at once.
    private func dockBar() {
        categoryBar.removeFromSuperview()
        categoryBar.translatesAutoresizingMaskIntoConstraints = true
        categoryBar.sizeToFit()
        navigationItem.titleView = categoryBar
        forceNavigationBarLayout()
    }

    /// Returns the selector to its slot in the scrolling column.
    ///
    /// One bar, re-parented — not two kept in step. The bar owns its selection,
    /// its lens position and its badge geometry, and a second copy would be a
    /// second answer to every one of those, correct only for as long as
    /// somebody remembered to forward the next change to both.
    private func undockBar() {
        navigationItem.titleView = nil
        categoryBar.removeFromSuperview()
        categoryBar.translatesAutoresizingMaskIntoConstraints = false
        inlineBarSlot.addSubview(categoryBar)
        NSLayoutConstraint.activate([
            categoryBar.leadingAnchor.constraint(
                greaterThanOrEqualTo: inlineBarSlot.layoutMarginsGuide.leadingAnchor
            ),
            categoryBar.centerYAnchor.constraint(equalTo: inlineBarSlot.centerYAnchor),
            categoryBar.centerXAnchor.constraint(equalTo: inlineBarSlot.centerXAnchor)
        ])
        forceNavigationBarLayout()
    }

    /// The nav bar caches its title view's size, so a bar arriving in or leaving
    /// the title slot has to make it re-measure — the same re-layout the other
    /// two screens force whenever a badge changes their bar's width.
    private func forceNavigationBarLayout() {
        guard let bar = navigationController?.navigationBar else { return }
        bar.setNeedsLayout()
        bar.layoutIfNeeded()
    }

    /// Docks the selector into the navigation bar once its inline slot has
    /// scrolled under the chrome, and gives it back when it comes out again.
    private func updateBarDocking() {
        guard viewModel.hasGallery, isViewLoaded else { return }
        let slotTop = inlineBarSlot.convert(inlineBarSlot.bounds, to: view).minY
        let line = view.safeAreaInsets.top
        let shouldDock = isBarDocked
            ? slotTop < line + Metrics.dockingHysteresis
            : slotTop <= line
        guard shouldDock != isBarDocked else { return }
        isBarDocked = shouldDock
        if shouldDock { dockBar() } else { undockBar() }
    }

    /// Keeps a docked selector docked when the tab under it changes.
    ///
    /// ⚠️ **Switching tabs used to throw the whole profile back to the top**,
    /// and nothing was scrolling it: a short tab makes the gallery shorter,
    /// which makes the scroll view's CONTENT shorter, and a scroll view whose
    /// content no longer reaches the current offset pulls the offset back. The
    /// identity block reappearing was the clamp, not a scroll.
    ///
    /// So the gallery is held to at least a screenful — but ONLY while the
    /// selector is docked, which is the only state that can be lost. A short
    /// tab read from the top of the profile keeps its natural height and the
    /// empty space that a floor would add underneath it.
    ///
    /// ⚠️ The floor is a CONSTANT — one viewport below the chrome — rather than
    /// something derived from the current offset. An offset-derived floor grows
    /// the content, which allows a larger offset, which grows the floor: the
    /// page would scroll forever under a finger that never lifted.
    ///
    /// It is released only at the very top, where releasing it cannot clamp
    /// anything. Dropping it the instant the selector undocks would shrink the
    /// content while the viewer was still somewhere inside it — trading this
    /// bug for a smaller version of itself.
    private func updateGalleryFloor() {
        guard viewModel.hasGallery else { return }
        if isBarDocked {
            galleryPager.setMinimumHeight(max(0, scrollView.bounds.height - view.safeAreaInsets.top))
        } else if scrollView.contentOffset.y <= 0 {
            galleryPager.setMinimumHeight(0)
        }
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
            scrollView.isHidden = false
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
            refreshControl.endRefreshing()
            statusLabel.isHidden = true
            scrollView.isHidden = false
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
            refreshControl.endRefreshing()
            // Never leave the previous profile held over an error.
            scrollView.isHidden = true
            skeletonViewportFill?.isActive = false
            headerView.setRedacted(false)
            statusLabel.text = message
            statusLabel.isHidden = false
        }
    }
}

// MARK: - Docking the selector

extension ProfileViewController: UIScrollViewDelegate {
    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        updateBarDocking()
        updateGalleryFloor()
    }
}
