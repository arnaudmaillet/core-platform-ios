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
    /// Builds the account settings screen (own profile only, the gear's
    /// destination). Nil for other users.
    private let makeSettingsViewController: (() -> UIViewController)?
    /// Builds the reusable profile-switcher menu (own profile only). Nil for
    /// other users — switching is a viewer affordance.
    private let switcherFactory: ProfileSwitcherMenuFactory?

    private let scrollView = UIScrollView()
    /// Retained for the share sheet, which builds its own QR card (and a
    /// throwaway one to rasterize) and needs the same avatar cache.
    private let imagePipeline: ImagePipeline
    /// Supplies the share sheet's quick-send row; nil hides it.
    private let shareTargeting: (any ProfileShareTargeting)?
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

    /// The own-profile settings gear; pushes `AccountSettingsViewController`.
    private var settingsItem: UIBarButtonItem?
    /// The own-profile switcher; taps present the profile-switcher menu.
    private var switcherItem: UIBarButtonItem?
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
        shareTargeting: (any ProfileShareTargeting)? = nil,
        onLogout: (() -> Void)?,
        makeEditViewController: ((@escaping () -> Void) -> UIViewController)? = nil,
        makeSettingsViewController: (() -> UIViewController)? = nil,
        switcherFactory: ProfileSwitcherMenuFactory? = nil,
        identityStub: ProfileIdentityStub? = nil
    ) {
        self.viewModel = viewModel
        self.onLogout = onLogout
        self.makeEditViewController = makeEditViewController
        self.makeSettingsViewController = makeSettingsViewController
        self.switcherFactory = switcherFactory
        self.imagePipeline = imagePipeline
        self.shareTargeting = shareTargeting
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
        headerView.onEditTapped = { [weak self] in
            self?.pushEditProfile()
        }
        headerView.onWebsiteTapped = { url in
            UIApplication.shared.open(url)
        }
        headerView.onQRCodeTapped = { [weak self] in
            self?.presentShareSheet()
        }
        configureMoreMenu()
        viewModel.onActionResult = { [weak self] result in
            self?.render(result)
        }
        viewModel.onDismissRequested = { [weak self] in
            self?.leaveAfterBlock()
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
                guard chained == "activity" || chained == "send" else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                    let sheet = self?.presentedViewController as? ProfileShareViewController
                    if chained == "activity" {
                        sheet?.qaHandOffToSystemShare()
                    } else {
                        sheet?.qaSendToFirstTarget()
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
        let bottom = view.safeAreaInsets.bottom + (viewModel.hasGallery ? 8 : 0)
        if scrollView.contentInset.bottom != bottom {
            scrollView.contentInset.bottom = bottom
            scrollView.verticalScrollIndicatorInsets.bottom = bottom
        }
    }

    /// The nav-bar relationship action toggles Follow / Following. Edit is not
    /// a bar item — it's the header tray's own capsule (`onEditTapped`), so it
    /// never routes through here.
    private func handleActionTapped() {
        viewModel.toggleFollow()
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
            card: card, imagePipeline: imagePipeline, targeting: shareTargeting
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

        // Profile switcher — a standalone item beside the gear. Tapping presents
        // the shared switcher menu; a switch refreshes this screen to the new
        // active profile (the map avatar refreshes via `.activeProfileDidChange`).
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
    private func reloadSwitcherMenu() {
        guard let switcherFactory, let switcherItem else { return }
        Task { [weak self] in
            await switcherFactory.reload()
            switcherItem.menu = switcherFactory.makeMenu(
                onSwitch: { [weak self] in
                    self?.viewModel.refresh()
                    self?.reloadSwitcherMenu()
                },
                onAddProfile: { [weak self] in self?.presentAddProfilePlaceholder() }
            )
        }
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
        // Edit is no longer a bar item — it lives in the header tray beside the
        // avatar (see `ProfileHeaderView.configureAction`), so own-profile keeps
        // only its account overflow menu here.
        let action: UIBarButtonItem? = switch state {
        case .hidden: actionPlaceholderItem
        case .follow: makeActionItem(title: "Follow")
        case .following: makeActionItem(title: "Following")
        case .edit: nil
        }
        // Relationship action for other users; the gear + switcher for own
        // profile (where `action` is nil). Trailing-to-leading: gear rightmost,
        // switcher to its left, with a fixedSpace so they read as two distinct
        // glass bubbles rather than one grouped capsule.
        var items: [UIBarButtonItem] = []
        if let action { items.append(action) }
        if let settingsItem { items.append(settingsItem) }
        if let switcherItem {
            if !items.isEmpty { items.append(.fixedSpace(8)) }
            items.append(switcherItem)
        }
        navigationItem.rightBarButtonItems = items
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
