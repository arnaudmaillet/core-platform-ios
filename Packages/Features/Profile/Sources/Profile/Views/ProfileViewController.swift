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
    private let refreshControl = UIRefreshControl()
    private let spinner = UIActivityIndicatorView(style: .large)
    private let statusLabel = UILabel()

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
        super.init(nibName: nil, bundle: nil)

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
    }

    #if DEBUG
    private var didAutoPresentEdit = false
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
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
    }
    #endif

    override func viewSafeAreaInsetsDidChange() {
        super.viewSafeAreaInsetsDidChange()
        // With a transparent bar the view extends under the chrome, so the top
        // safe-area inset is exactly the status-bar + navigation-bar height the
        // header's overlay content must clear.
        headerView.chromeTopInset = view.safeAreaInsets.top
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
            headerView.bottomAnchor.constraint(equalTo: content.bottomAnchor)
            headerView.widthAnchor.constraint(equalTo: frame.widthAnchor)
        }
        // Stretchy banner: on downward overscroll the banner must keep
        // covering the screen from the very top instead of riding down with
        // the header and exposing the background.
        headerView.anchorBanner(toViewportTop: frame.topAnchor)

        spinner.hidesWhenStopped = true
        spinner.constrain(in: view) { parent in
            spinner.centerXAnchor.constraint(equalTo: parent.centerXAnchor)
            spinner.centerYAnchor.constraint(equalTo: parent.centerYAnchor)
        }

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

    // MARK: - Render

    private func render(_ phase: ProfileViewModel.Phase) {
        switch phase {
        case .loading:
            if !refreshControl.isRefreshing { spinner.startAnimating() }
            scrollView.isHidden = true
            statusLabel.isHidden = true

        case .content(let model):
            spinner.stopAnimating()
            refreshControl.endRefreshing()
            statusLabel.isHidden = true
            scrollView.isHidden = false
            // Instagram-style: the @handle is the screen's title (the header
            // shows the bold display name). "Profile" only until first load.
            // Content usually lands mid-push; rebind inside the transition
            // so the bar text doesn't snap in after the animation settles.
            currentHandle = model.handle
            alongsideTransition { $0.applyNavigationState() }
            headerView.configure(with: model)

        case .failed(let message):
            spinner.stopAnimating()
            refreshControl.endRefreshing()
            scrollView.isHidden = true
            statusLabel.text = message
            statusLabel.isHidden = false
        }
    }
}
