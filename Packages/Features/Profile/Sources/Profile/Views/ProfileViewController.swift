import MediaCore
import CoreModels
import DesignSystem
import UIKit

final class ProfileViewController: UIViewController {
    private let viewModel: ProfileViewModel
    /// Non-nil only for the signed-in viewer's own profile (the Profile tab);
    /// nil for a profile pushed via routing, which shows no account actions.
    private let onLogout: (() -> Void)?
    /// Builds the edit form (for the viewer's own profile); the closure it
    /// receives is invoked after a successful save. Nil for other users.
    private let makeEditViewController: ((@escaping () -> Void) -> UIViewController)?

    private let scrollView = UIScrollView()
    private let headerView: ProfileHeaderView
    private let galleryPager: ProfileGalleryPagerView
    /// The filter tray's two selectors, hosted as custom bar items in the
    /// navigation controller's native toolbar. They carry no material of
    /// their own: the iOS 26 bar wraps each item in the system's Liquid
    /// Glass capsule (same rule as the nav-bar items — see
    /// `updateActionBarItem`). Ownership of the shared toolbar is handed
    /// over between screens by the successor rule — see
    /// `concealFilterToolbar` and `SnapFeedViewController.concealToolbar`.
    private let formatRow = GlassSegmentRow(segments: [
        .title("Activity"), .title("Media"), .title("Short")
    ])
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

    /// The own-profile overflow menu (Log Out); sits inside the action item.
    private var overflowItem: UIBarButtonItem?
    /// Defensive rendering for a `.hidden` relationship state. In practice the
    /// slot always has a concrete default from init ("Follow" / "Edit
    /// Profile"), so this skeleton only shows if a future code path ever
    /// emits `.hidden` — the slot must still never be empty. A bare,
    /// non-interactive custom view on purpose: the iOS 26 bar wraps every
    /// item in its own neutral glass capsule, so an empty view reads as a
    /// quiet placeholder pill in native chrome (a titled item can't be
    /// textless, and any material of our own would stack a second
    /// background).
    private lazy var actionPlaceholderItem: UIBarButtonItem = {
        let skeleton = UIView()
        let bone = UIView()
        bone.backgroundColor = .tertiarySystemFill
        bone.layer.cornerRadius = 4
        bone.constrain(in: skeleton) { parent in
            bone.centerXAnchor.constraint(equalTo: parent.centerXAnchor)
            bone.centerYAnchor.constraint(equalTo: parent.centerYAnchor)
            bone.widthAnchor.constraint(equalToConstant: 44)
            bone.heightAnchor.constraint(equalToConstant: 8)
        }
        NSLayoutConstraint.activate([
            skeleton.widthAnchor.constraint(equalToConstant: 56),
            skeleton.heightAnchor.constraint(equalToConstant: 22)
        ])
        let item = UIBarButtonItem(customView: skeleton)
        item.isEnabled = false
        return item
    }()
    /// The loaded profile's @handle — the screen title once known. Stashed so
    /// `viewWillAppear` can bind the bar from current state before the push
    /// animation starts, whenever the data beat the transition.
    private var currentHandle: String?

    private var followButtonState: ProfileViewModel.FollowButton = .hidden

    init(
        viewModel: ProfileViewModel,
        imagePipeline: ImagePipeline,
        onLogout: (() -> Void)?,
        makeEditViewController: ((@escaping () -> Void) -> UIViewController)? = nil,
        identityStub: ProfileIdentityStub? = nil
    ) {
        self.viewModel = viewModel
        self.onLogout = onLogout
        self.makeEditViewController = makeEditViewController
        headerView = ProfileHeaderView(imagePipeline: imagePipeline)
        galleryPager = ProfileGalleryPagerView(imagePipeline: imagePipeline)
        super.init(nibName: nil, bundle: nil)

        // The gallery's filter tray floats at the screen bottom; the tab bar
        // would stack underneath it. Safe with the standard pop gesture (chat
        // thread precedent); the feed-pushed contexts hide the bar manually
        // anyway, where this flag is a no-op.
        hidesBottomBarWhenPushed = true

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
        if let isFollowing = identityStub?.isFollowing {
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
        headerView.onWebsiteTapped = { url in
            UIApplication.shared.open(url)
        }
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
                self.formatRow.select(index, notify: false)
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

    #if DEBUG
    private var didAutoPresentEdit = false
    #endif

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
        // Dev convenience: `-edit-profile` opens the edit form on the viewer's
        // own profile, so the form is testable without tapping the button.
        if !didAutoPresentEdit, makeEditViewController != nil,
           ProcessInfo.processInfo.arguments.contains("-edit-profile") {
            didAutoPresentEdit = true
            presentEditProfile()
        }
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
        let bottom = view.safeAreaInsets.bottom + (viewModel.hasGallery ? 8 : 0)
        if scrollView.contentInset.bottom != bottom {
            scrollView.contentInset.bottom = bottom
            scrollView.verticalScrollIndicatorInsets.bottom = bottom
        }
    }

    /// The header's action button means different things per state: Edit opens
    /// the edit form; Follow/Following toggle the relationship.
    private func handleActionTapped() {
        if followButtonState == .edit {
            presentEditProfile()
        } else {
            viewModel.toggleFollow()
        }
    }

    private func presentEditProfile() {
        guard let makeEditViewController else { return }
        let editViewController = makeEditViewController { [weak self] in
            self?.dismiss(animated: true)
            self?.viewModel.refresh()
        }
        present(UINavigationController(rootViewController: editViewController), animated: true)
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

        // Account actions only exist for the viewer's own profile.
        guard let onLogout else { return }
        // Log Out lives in an overflow menu — destructive, so it's one tap
        // removed from the surface, matching where it sat on the placeholder.
        let logout = UIAction(title: "Log Out", image: UIImage(systemName: "rectangle.portrait.and.arrow.right"), attributes: .destructive) { _ in
            onLogout()
        }
        overflowItem = UIBarButtonItem(
            image: UIImage(systemName: "ellipsis.circle"),
            menu: UIMenu(children: [logout])
        )
    }

    /// The single application point for everything the navigation bar shows —
    /// title (@handle once loaded, "Profile" until then) and the relationship
    /// action. Idempotent, driven from three places: viewDidLoad (initial
    /// composition), viewWillAppear (synchronous pre-transition bind), and the
    /// async data callbacks (via `alongsideTransition`).
    private func applyNavigationState() {
        title = currentHandle ?? "Profile"
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
        let action: UIBarButtonItem = switch state {
        case .hidden: actionPlaceholderItem
        case .follow: makeActionItem(title: "Follow")
        case .following: makeActionItem(title: "Following")
        case .edit: makeActionItem(title: "Edit Profile")
        }
        navigationItem.rightBarButtonItems = [action] + (overflowItem.map { [$0] } ?? [])
    }

    private func makeActionItem(title: String) -> UIBarButtonItem {
        UIBarButtonItem(title: title, style: .plain, target: self, action: #selector(actionBarItemTapped))
    }

    @objc private func actionBarItemTapped() {
        handleActionTapped()
    }

    private func configureViews() {
        scrollView.alwaysBounceVertical = true
        // The header's banner must start at y = 0 of the screen, so the scroll
        // view must not push content below the (transparent) navigation bar;
        // the header re-adds the chrome height for its overlay content via
        // `chromeTopInset` (see viewSafeAreaInsetsDidChange).
        scrollView.contentInsetAdjustmentBehavior = .never
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
        // The gallery pager continues the header's column; its height tracks
        // the active page, so together they define the content height.
        galleryPager.isHidden = !viewModel.hasGallery
        galleryPager.constrain(in: scrollView) { _ in
            galleryPager.topAnchor.constraint(equalTo: headerView.bottomAnchor, constant: 12)
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

    /// Wires the bottom filter tray and installs it as this screen's toolbar
    /// items: a format tab records the selection and pages the gallery; a
    /// source pick re-filters every page in place. The items must exist by
    /// the time a push starts — the feed's handover rule reads the incoming
    /// screen's `toolbarItems` in its own viewWillDisappear.
    private func configureFilterTray() {
        guard viewModel.hasGallery else { return }

        formatRow.onSelect = { [weak self] index in
            guard let self else { return }
            let format = ProfileGalleryPagerView.pageOrder[index]
            self.viewModel.setGalleryFormat(format)
            self.galleryPager.setActivePage(format, animated: true)
        }
        // Land on the user's global preference: tab selection and pager page
        // adopt the (possibly stored) filter before first layout, so the
        // screen OPENS there — no visible jump.
        let format = viewModel.galleryFilter.format
        if let index = ProfileGalleryPagerView.pageOrder.firstIndex(of: format) {
            formatRow.select(index, notify: false)
        }
        galleryPager.setActivePage(format, animated: false)
        toolbarItems = [
            UIBarButtonItem(customView: formatRow),
            .flexibleSpace(),
            UIBarButtonItem(customView: sourceMenuButton)
        ]
    }

    /// Shows the shared toolbar for this screen, riding the transition. The
    /// mechanics mirror the feed's `presentToolbar`: shown non-animated so the
    /// safe area is final immediately; the *visual* entrance is an alpha fade
    /// on the transition coordinator — but only when the bar was hidden. When
    /// it arrives from another toolbar owner (pushed from the feed), the bar
    /// is already up and UIKit cross-fades the items natively.
    private func presentFilterToolbar() {
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
            headerView.setRedacted(true)
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
            headerView.configure(with: model)
            headerView.setRedacted(false, animated: view.window != nil)

        case .failed(let message):
            refreshControl.endRefreshing()
            scrollView.isHidden = true
            skeletonViewportFill?.isActive = false
            headerView.setRedacted(false)
            statusLabel.text = message
            statusLabel.isHidden = false
        }
    }
}
