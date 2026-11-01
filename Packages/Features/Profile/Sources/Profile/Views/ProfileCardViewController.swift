import CoreModels
import CoreNavigation
import DesignSystem
import MediaCore
import MediaPlayback
import PostGrid
import ProfileInterface
import ShareSheet
import UIKit

/// Someone's profile as a CARD (#1524, the owner 2026-10-21): what a bottom
/// toolbar's author pill opens instead of pushing the profile.
///
/// ```
///  [🔔][▦]                       [✕]   ← the sheet's own bar, over the banner
///  ░░░░ the band card, 2nd notch ░░░░
///      (avatar)  Name ✓ · counters      ← the PROFILE'S header, same views
///   bio … link
///  [ Follow ] [ Message ]       [•••]  ← native toolbar items
/// ```
///
/// - **The header is the profile's** (`ProfileHeaderView`), its tray hidden
///   (`showsActionTray`): its actions are this sheet's bars. A change to the
///   profile's header shows here too.
/// - **The banner stands where the profile's does at its second notch**: the
///   header is laid out as on the profile and climbed by `bandAvatarDetent`
///   (`HeroBannerMetrics.bandAvatarDetentGap`), the same arithmetic the
///   profile's scroll detent uses, so the two cannot drift.
/// - **One detent, measured to the content**, never taller: the climbed
///   header and the toolbar. The sheet's own glass is the surface (a clear
///   view, as `CountryUnlockSheetViewController`).
/// - **The profile info opens the profile**: the card closes, then
///   `Actions.openProfile` pushes it on the presenter's stack. The counters
///   push their lists the same way (`Actions.push`).
@MainActor
final class ProfileCardViewController: UIViewController {
    struct Actions {
        /// Pushes the full profile; called once the card has closed.
        var openProfile: () -> Void
        /// Pushes a screen on the presenter's stack; called once the card
        /// has closed.
        var push: (UIViewController) -> Void
    }

    static let detent = UISheetPresentationController.Detent.Identifier("profile.card")

    let viewModel: ProfileViewModel
    private let imagePipeline: ImagePipeline
    private let shareTargeting: (any ProfileShareTargeting)?
    private let makeRelationshipsViewController: (
        (ProfileRelationshipsViewModel.Subject, RelationshipDirection) -> UIViewController
    )?
    private let actions: Actions
    let headerView: ProfileHeaderView
    /// Clips the header to what the card shows of it: from the climb down.
    private let headerClip = UIView()
    /// The card's failure and not-found block (#1767): with no profile to
    /// show, the header goes (`ProfileHeaderView.render`), and the sheet was
    /// left blank — no message, no way to try again.
    private let statusView = EmptyStateView()
    private var headerTop: NSLayoutConstraint?
    private var headerClipHeight: NSLayoutConstraint?
    /// The relationship, as the toolbar shows it.
    private(set) var followButtonState: ProfileViewModel.FollowButton

    /// The header's climb: the profile's second notch, or nothing off a band.
    private(set) var climb: CGFloat = 0
    /// The header as the card shows it, measured.
    private(set) var visibleHeaderHeight: CGFloat = 320
    /// The toolbar's band above the home indicator: the bar's estimate until
    /// the sheet is on screen, then what its safe area says.
    private(set) var toolbarBand: CGFloat = 52
    /// The detent: the climbed header and the toolbar. A custom detent's
    /// height excludes the bottom safe area — the sheet adds it back.
    var sheetHeight: CGFloat { visibleHeaderHeight + toolbarBand }

    init(
        viewModel: ProfileViewModel,
        imagePipeline: ImagePipeline,
        shareTargeting: (any ProfileShareTargeting)?,
        makeRelationshipsViewController: (
            (ProfileRelationshipsViewModel.Subject, RelationshipDirection) -> UIViewController
        )?,
        identityStub: ProfileIdentityStub?,
        actions: Actions,
        videoPlayback: VideoPlaybackController? = nil
    ) {
        self.viewModel = viewModel
        self.imagePipeline = imagePipeline
        self.shareTargeting = shareTargeting
        self.makeRelationshipsViewController = makeRelationshipsViewController
        self.actions = actions
        headerView = ProfileHeaderView(imagePipeline: imagePipeline)
        // The video banner plays here as on the profile (#1541), on the app's
        // one pool.
        headerView.bannerVideoPool = videoPlayback
        // The origin's answer when it had one, as the profile seeds it.
        followButtonState = identityStub?.isFollowing.map { $0 ? .following : .follow } ?? .hidden
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// The card as it is presented: the root of a navigation controller
    /// whose transparent bar carries the bell, the QR and ✕, and whose
    /// toolbar carries Follow, Message and •••, as a page sheet of one
    /// measured detent.
    func wrappedInSheet() -> UINavigationController {
        let navigation = UINavigationController(rootViewController: self)
        navigation.setToolbarHidden(false, animated: false)
        navigation.modalPresentationStyle = .pageSheet
        if let sheet = navigation.sheetPresentationController {
            sheet.detents = [.custom(identifier: Self.detent) { [weak self] context in
                min(self?.sheetHeight ?? 420, context.maximumDetentValue)
            }]
            sheet.prefersGrabberVisible = false
            sheet.prefersScrollingExpandsWhenScrolledToEdge = false
        }
        return navigation
    }

    // MARK: - View

    override func viewDidLoad() {
        super.viewDidLoad()
        // Clear: the sheet's own glass is the surface.
        view.backgroundColor = .clear
        edgesForExtendedLayout = .all
        configureNavigationBar()
        configureHeader()
        bindViewModel()
        // ⚠️ THE LOADING STATE, DRAWN (#1757), as the profile draws it: the
        // view model STARTS in `.loading` and never announces it, so the card
        // sat in the header's blank default state until the profile landed —
        // empty labels, the verified badge, empty initials on a translucent
        // plate (a "transparent" avatar), a banner with no bone. A cache hit
        // in `viewDidLoad` below replaces it in this same pass.
        statusView.isHidden = true
        statusView.pin(to: headerClip)
        render(.loading)
        applyBars()
        applyRelationMark()
        viewModel.viewDidLoad()
        NotificationCenter.default.addObserver(
            self, selector: #selector(decorativeMotionDidChange), name: .decorativeMotionDidChange, object: nil
        )
    }

    // MARK: - The moving pictures (#1541)

    /// On show, or leaving (the banner plays on through the dismissal, as
    /// the profile's does, #1399).
    private var isShowing = false

    /// The header's one rule (`ProfileHeaderView.bannerShouldPlay`).
    private func updateBannerVideo() {
        headerView.updateBannerVideo(hostShowing: isShowing)
    }

    @objc private func decorativeMotionDidChange() {
        updateBannerVideo()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        // A guest is known only once the presenter's gate is up the chain.
        applyRelationMark()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        isShowing = true
        updateBannerVideo()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        isShowing = false
        updateBannerVideo()
    }

    override func viewSafeAreaInsetsDidChange() {
        super.viewSafeAreaInsetsDidChange()
        // The bar's foot: where the identity column starts, as the profile's
        // starts under its chrome.
        headerView.chromeTopInset = view.safeAreaInsets.top
        remeasure()
    }

    override func viewIsAppearing(_ animated: Bool) {
        super.viewIsAppearing(animated)
        // On screen: the toolbar's real band, read off the safe area (the
        // country sheet's measure).
        if let window = view.window {
            let band = max(0, view.safeAreaInsets.bottom - window.safeAreaInsets.bottom)
            if band > 0, band < 120 { toolbarBand = band }
        }
        remeasure()
    }

    private func configureNavigationBar() {
        let transparent = UINavigationBarAppearance()
        transparent.configureWithTransparentBackground()
        navigationItem.standardAppearance = transparent
        navigationItem.scrollEdgeAppearance = transparent
        navigationItem.largeTitleDisplayMode = .never
        let close = UIBarButtonItem(
            systemItem: .close,
            primaryAction: UIAction { [weak self] _ in self?.close() }
        )
        close.identifier = "profileCard.close"
        navigationItem.rightBarButtonItem = close
    }

    private func configureHeader() {
        headerView.showsActionTray = false
        headerClip.clipsToBounds = true
        headerClip.translatesAutoresizingMaskIntoConstraints = false
        headerView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(headerClip)
        headerClip.addSubview(headerView)
        let top = headerView.topAnchor.constraint(equalTo: headerClip.topAnchor)
        let height = headerClip.heightAnchor.constraint(equalToConstant: visibleHeaderHeight)
        height.priority = UILayoutPriority(999)
        headerTop = top
        headerClipHeight = height
        NSLayoutConstraint.activate([
            headerClip.topAnchor.constraint(equalTo: view.topAnchor),
            headerClip.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            headerClip.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            height,
            top,
            headerView.leadingAnchor.constraint(equalTo: headerClip.leadingAnchor),
            headerView.trailingAnchor.constraint(equalTo: headerClip.trailingAnchor),
        ])
        // The profile info — the avatar, the name, the bio, the banner — opens
        // the profile. Its controls (the counters, the link) keep their taps.
        let infoTap = UITapGestureRecognizer(target: self, action: #selector(infoTapped))
        infoTap.delegate = self
        headerClip.addGestureRecognizer(infoTap)
        headerView.onRelationshipsTapped = { [weak self] direction in self?.openRelationships(direction) }
        headerView.onWebsiteTapped = { url in UIApplication.shared.open(url) }
        // The header re-measures itself when its content changes.
        headerView.onPicturesSettled = { [weak self] in self?.remeasure() }
        // And when the text size changes under it: at XXXL the bio grew under
        // the toolbar, the sheet still at the old height (#1542's check).
        // A turn later: the header's labels take their new fonts in the same
        // trait pass, after this callback.
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { (card: Self, _) in
            DispatchQueue.main.async { [weak card] in card?.remeasure() }
        }
    }

    /// Lays the header out at the sheet's width, climbs it to the profile's
    /// second notch, and asks the sheet for the new height when it moved.
    func remeasure() {
        let width = view.bounds.width > 0 ? view.bounds.width
            : (presentingViewController?.view.window?.bounds.width ?? UIScreen.main.bounds.width)
        headerView.frame.size.width = width
        headerView.setNeedsLayout()
        headerView.layoutIfNeeded()
        let fitting = headerView.systemLayoutSizeFitting(
            CGSize(width: width, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required, verticalFittingPriority: .fittingSizeLevel
        )
        let newClimb = Self.climb(bandAvatarDetent: headerView.bandAvatarDetent)
        let visible = Self.visibleHeight(headerHeight: fitting.height, climb: newClimb)
        climb = newClimb
        headerTop?.constant = -newClimb
        headerView.setTravelled(newClimb)
        headerClipHeight?.constant = visible
        guard abs(visible - visibleHeaderHeight) > 0.5 else { return }
        visibleHeaderHeight = visible
        let presentation = navigationController?.sheetPresentationController
        presentation?.animateChanges { presentation?.invalidateDetents() }
    }

    /// The header's climb: the profile's second notch on a band, none
    /// otherwise (the header starts under the bar). Pure, for tests.
    nonisolated static func climb(bandAvatarDetent: CGFloat?) -> CGFloat {
        max(0, bandAvatarDetent ?? 0)
    }

    /// What the card shows of a header `headerHeight` tall, climbed by
    /// `climb`. Pure, for tests.
    nonisolated static func visibleHeight(headerHeight: CGFloat, climb: CGFloat) -> CGFloat {
        max(0, (headerHeight - climb).rounded(.up))
    }

    // MARK: - The view model

    private func bindViewModel() {
        viewModel.onPhaseChange = { [weak self] phase in self?.render(phase) }
        viewModel.onFollowButtonChange = { [weak self] state in
            self?.followButtonState = state
            self?.applyBars()
            self?.applyRelationMark()
        }
        viewModel.onMuteScopesChange = { [weak self] _ in self?.applyBars() }
        viewModel.onActionResult = { [weak self] result in self?.render(result) }
        viewModel.onUndoable = { [weak self] action in
            guard let self else { return }
            Feedback.undoable(action.message, symbol: action.symbol, from: self, commit: action.commit, undo: action.undo)
        }
        // A block leaves the card: there is no one left to show.
        viewModel.onDismissRequested = { [weak self] in self?.close() }
    }

    private func render(_ phase: ProfileViewModel.Phase) {
        // The profile's own mapping (`ProfileHeaderView.render`): the card
        // and the profile can no longer drift apart.
        headerView.render(phase, profileKnown: viewModel.profile != nil, animated: view.window != nil)
        renderStatus(phase)
        // The banner's clip arrives with the profile.
        if case .content = phase { updateBannerVideo() }
        remeasure()
        applyBars()
    }

    /// The block the profile shows in the same phases (`ProfileViewController`):
    /// a failure with Try Again, a not-found as an answer — only when there is
    /// no profile to keep showing.
    private func renderStatus(_ phase: ProfileViewModel.Phase) {
        guard viewModel.profile == nil else {
            statusView.isHidden = true
            return
        }
        switch phase {
        case .failed(let message):
            statusView.configure(
                symbolName: "exclamationmark.triangle", title: message,
                actionTitle: "Try Again", actionHandler: { [weak self] in
                    self?.statusView.setActionBusy(true)
                    self?.viewModel.refresh()
                }
            )
            statusView.isHidden = false
        case .notFound(let message, let detail):
            statusView.configure(symbolName: "person.crop.circle.badge.questionmark", title: message, subtitle: detail)
            statusView.isHidden = false
        case .loading, .seeded, .content:
            statusView.isHidden = true
        }
    }

    #if DEBUG
    /// Whether the card shows its failure or not-found block.
    var debugShowsStatus: Bool { !statusView.isHidden }
    #endif

    private func render(_ result: ProfileViewModel.ActionResult) {
        switch result {
        case .blocked(let handle, let profileCount):
            let message = profileCount > 1 ? "Blocked \(handle) and \(profileCount - 1) more" : "Blocked \(handle)"
            Feedback.success(message, symbol: "hand.raised.fill", from: presentingViewController ?? self)
        case .unblocked(let handle):
            Feedback.success("Unblocked \(handle)", symbol: "hand.raised.slash.fill", from: self)
            applyRelationMark()
        case .muteChanged(let handle, let scopes):
            Feedback.success(
                ProfileViewModel.muteMessage(handle: handle, scopes: scopes),
                symbol: scopes.isEmpty ? "speaker.wave.2.fill" : "speaker.slash.fill", from: self
            )
        case .restrictChanged(let handle, let restricted):
            Feedback.success(
                restricted ? "Restricted \(handle)" : "Unrestricted \(handle)",
                symbol: restricted ? "person.crop.circle.badge.minus" : "person.crop.circle.badge.checkmark",
                from: self
            )
        case .commitFailed(let message), .followFailed(let message):
            Feedback.failure(message, from: self)
        case .reported:
            Feedback.success("Report sent", symbol: "flag.fill", from: self)
        case .failed(let message):
            let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "OK", style: .default))
            present(alert, animated: true)
        }
    }

    // MARK: - The bars

    /// Who the member gate is asked of: the presenter's chain reaches the
    /// shell, a sheet's own does not.
    private var gateSource: UIResponder { navigationController?.presentingViewController ?? self }
    private var isGuest: Bool { MemberGates.isGuest(gateSource) }

    /// The bell stands while the viewer follows, for a member, as on the
    /// profile (`ProfileViewController.showsMuteBell`).
    var showsMuteBell: Bool {
        Self.showsMuteBell(followButton: followButtonState, canMute: viewModel.canMute, isGuest: isGuest)
    }

    /// Pure, for tests.
    nonisolated static func showsMuteBell(
        followButton: ProfileViewModel.FollowButton, canMute: Bool, isGuest: Bool
    ) -> Bool {
        followButton == .following && canMute && !isGuest
    }

    /// The toolbar's items for a relationship. Pure, for tests.
    nonisolated enum ToolbarItem: Equatable, Sendable {
        case follow, requested, openProfile, message, bell, qr
    }

    /// ⚠️ THE OWNER'S BARS (#1562, 2026-10-22): `[——Follow——][Message][QR]`
    /// while not followed, `[bell][——Message——][QR]` once followed — the
    /// mute bell down from the top bar, Following gone (Unfollow is in the
    /// ••• menu, now top left). `showsBell`: a member who can mute;
    /// `showsQR`: a share card to show (or the profile not loaded yet).
    nonisolated static func toolbarItems(
        for followButton: ProfileViewModel.FollowButton, showsBell: Bool = true, showsQR: Bool = true
    ) -> [ToolbarItem] {
        let qr: [ToolbarItem] = showsQR ? [.qr] : []
        switch followButton {
        case .follow: return [.follow, .message] + qr
        case .following: return (showsBell ? [.bell] : []) + [.message] + qr
        // A private profile asked: its request is withdrawn from its item.
        case .requested: return [.requested, .message] + qr
        // Not followable (#726), or unknown yet: what does not depend on it.
        case .unavailable, .hidden: return [.message] + qr
        // The viewer's own profile, reached by id: nothing to do here but
        // open it.
        case .edit: return [.openProfile]
        }
    }

    /// Whether the top bar carries the ••• menu: everywhere but the viewer's
    /// own profile, which only opens it. Pure, for tests.
    nonisolated static func showsMoreMenu(for followButton: ProfileViewModel.FollowButton) -> Bool {
        followButton != .edit
    }

    /// The item that takes the toolbar's free width (#1542, the owner): Follow
    /// while the viewer does not follow — `[——Follow——][Message][QR]` — and
    /// Requested once asked, in the same slot — `[——Requested——][Message][QR]`
    /// (#1668: the same item to UIKit, `barIdentifier`, never a bar whose
    /// stretched slot moves to Message); Message once followed or not
    /// followable.
    /// Nil: nothing stretches (the viewer's own profile). Pure, for tests.
    nonisolated static func wideItem(in items: [ToolbarItem]) -> ToolbarItem? {
        if items.contains(.follow) { return .follow }
        if items.contains(.requested) { return .requested }
        if items.contains(.message) { return .message }
        return nil
    }

    /// The identity UIKit matches a bar item by across a rebuild
    /// (`UIBarButtonItem.identifier`): by what it DOES, so Follow and
    /// Requested are one item in two states, Message stays Message when it
    /// takes the free width, and Follow is never taken for the bell that
    /// replaces it once followed (#1678). Pure, for tests.
    nonisolated static func barIdentifier(for item: ToolbarItem) -> String {
        switch item {
        case .follow, .requested: "profileCard.follow"
        case .message: "profileCard.message"
        case .openProfile: "profileCard.openProfile"
        case .bell: "profileCard.bell"
        case .qr: "profileCard.qr"
        }
    }

    /// The ••• menu's identity, top left, across rebuilds.
    nonisolated static let moreIdentifier = "profileCard.more"

    /// What the bars last showed: they are rebuilt only when it changes, so
    /// a phase or a refresh that leaves them alone does not redraw them.
    private struct BarState: Equatable {
        var muted: Bool
        var more: Bool
        var toolbar: [ToolbarItem]
    }

    private var shownBars: BarState?

    private func applyBars() {
        let state = BarState(
            muted: !viewModel.muteScopes.isEmpty,
            more: Self.showsMoreMenu(for: followButtonState),
            toolbar: Self.toolbarItems(
                for: followButtonState, showsBell: showsMuteBell,
                showsQR: viewModel.shareCard != nil || viewModel.profile == nil
            )
        )
        guard state != shownBars else { return }
        // ⚠️ REBUILT FOR EVERY CHANGE, AND ANIMATED BY THE BAR (#1678). #1672
        // restyled a custom-view `UIButton` in place inside a spring of its
        // own: "Follow" and "Requested" cross-faded over each other while the
        // tint turned (the owner's recording, 2026-10-24). No button now and
        // no animation of ours: the bar draws every bubble, and
        // `setToolbarItems` carries one set into the next, told which items
        // are the same (`barIdentifier`).
        shownBars = state
        // The ••• menu, top left (#1562).
        var leading: [UIBarButtonItem] = []
        if state.more {
            let more = UIBarButtonItem(image: UIImage(systemName: "ellipsis"), menu: makeMoreMenu())
            more.accessibilityLabel = "More"
            more.identifier = Self.moreIdentifier
            leading.append(more)
        }
        navigationItem.setLeftBarButtonItems(leading, animated: view.window != nil)

        var items: [UIBarButtonItem] = []
        let wide = Self.wideItem(in: state.toolbar)
        for kind in state.toolbar {
            // Each in its own bubble: the zero-width fixed space keeps UIKit
            // from joining two items in one shared platter (the sound
            // sheet's toolbar).
            if !items.isEmpty { items.append(.fixedSpace()) }
            let item = kind == wide ? wideItem(for: kind) : barItem(for: kind)
            item.identifier = Self.barIdentifier(for: kind)
            items.append(item)
        }
        setToolbarItems(items, animated: view.window != nil)
    }

    /// A toolbar item that does not stretch: a stock bar item.
    private func barItem(for kind: ToolbarItem) -> UIBarButtonItem {
        switch kind {
        case .follow:
            return followItem(title: "Follow", prominent: true)
        case .bell:
            return makeMuteBellItem()
        case .qr:
            let qr = UIBarButtonItem(
                image: UIImage(systemName: "qrcode"),
                primaryAction: UIAction { [weak self] _ in self?.presentShareSheet() }
            )
            qr.accessibilityLabel = "QR Code"
            return qr
        case .requested:
            // Never reached while Follow's slot is the stretched one; kept
            // for a bar that has no stretched slot.
            return followItem(title: "Requested", prominent: false)
        case .openProfile:
            let open = UIBarButtonItem(title: "View Profile", primaryAction: UIAction { [weak self] _ in
                self?.infoTapped()
            })
            open.style = .prominent
            return open
        case .message:
            return UIBarButtonItem(title: "Message", primaryAction: UIAction { [weak self] _ in
                self?.messageTapped()
            })
        }
    }

    /// The stretched item: a plain view holding its word, in an item whose
    /// bubble the BAR draws — its glass, its press, and its prominence for
    /// Follow — as the post screen's author pill is (#1678). A custom view,
    /// since there is no flexible-width bar item (a title item's `width` is
    /// ignored on iOS 27, measured again 2026-10-24); never a `UIButton`
    /// drawing a glass of its own. It hugs nothing and asks, at the lowest
    /// priority, for more room than any bar has, so the bar gives it exactly
    /// what the other items leave (#304).
    private func wideItem(for kind: ToolbarItem) -> UIBarButtonItem {
        let made: (item: UIBarButtonItem, label: StretchedBarLabel)
        let id = Self.barIdentifier(for: kind)
        switch kind {
        case .follow:
            made = BarItems.stretched(id: id, title: "Follow", prominent: true) { [weak self] in self?.followTapped() }
        case .requested:
            made = BarItems.stretched(id: id, title: "Requested") { [weak self] in self?.followTapped() }
        default:
            made = BarItems.stretched(id: id, title: "Message") { [weak self] in self?.messageTapped() }
        }
        made.label.accessibilityIdentifier = "profileCard.wide"
        wideLabel = made.label
        return made.item
    }

    /// The stretched item's view — what a test reads.
    private(set) weak var wideLabel: StretchedBarLabel?

    private func followItem(title: String, prominent: Bool) -> UIBarButtonItem {
        let item = UIBarButtonItem(title: title, primaryAction: UIAction { [weak self] _ in
            self?.followTapped()
        })
        if prominent { item.style = .prominent }
        return item
    }

    private func makeMuteBellItem() -> UIBarButtonItem {
        let scopes = viewModel.muteScopes
        let item = UIBarButtonItem(
            image: UIImage(systemName: scopes.isEmpty ? "bell" : "bell.slash"),
            menu: UIMenu(children: [UIDeferredMenuElement.uncached { [weak self] completion in
                guard let self else { return completion([]) }
                completion(ProfileMenuBuilder.muteMenuElements(viewModel.muteScopes) { [weak self] scope in
                    self?.viewModel.toggleMute(scope)
                })
            }])
        )
        item.accessibilityLabel = "Notifications"
        item.accessibilityValue = scopes.isEmpty ? "Nothing muted" : "Muted: " + scopes.summary
        return item
    }

    private func makeMoreMenu() -> UIMenu {
        UIMenu(children: [UIDeferredMenuElement.uncached { [weak self] completion in
            completion(self?.moreMenuElements() ?? [])
        }])
    }

    /// The profile's ••• menu (`ProfileMenuBuilder`), the same state and
    /// handlers. The QR is the bar's, never in it.
    #if DEBUG
    /// The relationship arriving as the view model would send it. Tests.
    func debugApplyFollowButton(_ state: ProfileViewModel.FollowButton) {
        followButtonState = state
        applyBars()
        applyRelationMark()
    }

    /// The ••• menu's rows, flattened. Tests.
    var debugMoreMenuTitles: [String] {
        func titles(_ elements: [UIMenuElement]) -> [String] {
            elements.flatMap { element -> [String] in
                guard let menu = element as? UIMenu, menu.title.isEmpty else { return [element.title] }
                return titles(menu.children)
            }
        }
        return titles(moreMenuElements())
    }
    #endif

    private func moreMenuElements() -> [UIMenuElement] {
        // Following has left the toolbar (#1562): Unfollow leads the menu.
        let unfollow: [UIMenuElement] = followButtonState == .following
            ? PostCardMenu.sections(for: [.unfollow { [weak self] in self?.followTapped() }], author: nil)
            : []
        return unfollow + ProfileMenuBuilder.moreMenuElements(
            ProfileMenuBuilder.MoreMenuState(
                canShare: viewModel.shareCard != nil,
                mapPin: viewModel.mapPinButton,
                canModerate: viewModel.canModerate,
                isGuest: isGuest,
                canRestrict: viewModel.canRestrict,
                isRestricted: viewModel.isRestricted,
                isBlocked: viewModel.isBlocked,
                canClearHistory: false
            ),
            handlers: ProfileMenuBuilder.MoreMenuHandlers(
                share: { [weak self] in self?.presentShareSheet() },
                copyLink: { [weak self] in self?.copyProfileLink() },
                toggleMapCategory: { [weak self] category in self?.viewModel.toggleMapCategory(category) },
                report: { [weak self] in self?.presentReportReasons() },
                toggleRestrict: { [weak self] in self?.viewModel.toggleRestrict() },
                unblock: { [weak self] in self?.viewModel.unblock() },
                confirmBlock: { [weak self] in self?.confirmBlock() },
                clearHistory: {}
            )
        )
    }

    /// Wears the relationship on the header's avatar (#2014): the
    /// profile's own mapping (`ProfileHeaderView.avatarMark`).
    private func applyRelationMark() {
        headerView.configureRelationMark(
            followButtonState, mutual: viewModel.isMutualFollow, blocked: viewModel.isBlocked, isGuest: isGuest
        )
    }

    // MARK: - Actions

    private func followTapped() {
        MemberGates.perform(.follow(handle: viewModel.profile?.handle), from: gateSource) { [weak self] in
            // On at the optimistic flip; off is silent (#1886).
            if self?.viewModel.toggleFollow() == true { Haptics.play(.toggleOn) }
        }
    }

    /// The conversation opens on the presenter's stack: the card goes first.
    private func messageTapped() {
        MemberGates.perform(.message(handle: viewModel.profile?.handle), from: gateSource) { [weak self] in
            self?.closeThen { [weak self] in self?.viewModel.messageTapped() }
        }
    }

    #if DEBUG
    /// A tap on the profile info. Tests.
    func debugTapInfo() { infoTapped() }
    #endif

    @objc private func infoTapped() {
        let open = actions.openProfile
        closeThen(open)
    }

    private func openRelationships(_ direction: RelationshipDirection) {
        guard let makeRelationshipsViewController, let subject = viewModel.relationshipsSubject else { return }
        let push = actions.push
        let screen = makeRelationshipsViewController(subject, direction)
        closeThen { push(screen) }
    }

    private func close() {
        closePresentation()
    }

    /// Closes the card, then runs `body` — on the presenter's stack, which
    /// a push made while the sheet still stood would land behind it.
    private func closeThen(_ body: @escaping () -> Void) {
        let presented: UIViewController = navigationController ?? self
        guard presented.presentingViewController != nil else { return body() }
        // Once: a second tap while the card leaves runs nothing (#1144).
        closePresentation(completion: body)
    }

    private func presentShareSheet() {
        guard let card = viewModel.shareCard else { return }
        let sheet = ProfileShareViewController(
            card: card,
            imagePipeline: imagePipeline,
            targeting: shareTargeting,
            deviceCornerRadius: ScreenGeometry.cornerRadius(behind: view),
            fallbackWidth: view.bounds.width
        )
        sheet.onSystemShare = { [weak self] card, image in
            guard let self else { return }
            let source = ProfileShareItemSource(card: card, icon: image)
            let activity = UIActivityViewController(activityItems: [source, image], applicationActivities: nil)
            activity.popoverPresentationController?.sourceView = view
            present(activity, animated: true)
        }
        sheet.onSendToTarget = { [weak self] target, card in
            self?.viewModel.sendProfile(card, to: target)
        }
        present(sheet, animated: true)
    }

    private func copyProfileLink() {
        guard let link = viewModel.shareLink else { return }
        UIPasteboard.general.url = link
        UIPasteboard.general.string = link.absoluteString
        Feedback.success("Link copied", symbol: "link", from: self)
    }

    private func presentReportReasons() {
        ReportReasonSheet.present(
            from: self, subject: viewModel.handle ?? "this profile", sourceView: view
        ) { [weak self] reason in
            self?.viewModel.report(reason)
        }
    }

    /// The profile's question, in its words (`ProfileViewController.confirmBlock`).
    private func confirmBlock() {
        let handle = viewModel.handle ?? "this user"
        let sheet = UIAlertController(
            title: "Block \(handle)?",
            message: "They won't be able to find your profile or message you, and you'll stop seeing their posts. They aren't notified.\n\nBlocking the account also blocks any other profiles it owns.",
            preferredStyle: .actionSheet
        )
        sheet.addAction(UIAlertAction(title: "Block \(handle)", style: .destructive) { [weak self] _ in
            self?.viewModel.block(.profile)
        })
        sheet.addAction(UIAlertAction(title: "Block Account & All Profiles", style: .destructive) { [weak self] _ in
            self?.viewModel.block(.account)
        })
        sheet.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        sheet.popoverPresentationController?.sourceView = view
        present(sheet, animated: true)
    }
}

extension ProfileCardViewController: UIGestureRecognizerDelegate {
    /// ⚠️ A CONTROL KEEPS ITS TAP: the counters are custom `UIControl`s,
    /// which UIKit does not shield from an ancestor's tap as it does a
    /// button — without this a tap on Followers opened the profile too.
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        !Self.touchLandsOnControl(touch.view, below: headerClip)
    }

    /// Whether `view` is, or sits inside, a control under `root`. Pure.
    static func touchLandsOnControl(_ view: UIView?, below root: UIView) -> Bool {
        var current = view
        while let candidate = current, candidate !== root {
            if candidate is UIControl { return true }
            current = candidate.superview
        }
        return false
    }
}
