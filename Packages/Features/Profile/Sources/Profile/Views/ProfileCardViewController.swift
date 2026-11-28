import CoreModels
import CoreNavigation
import DesignSystem
import MediaCore
import MediaPlayback
import PostGrid
import ProfileData
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
///  [——Follow——][💬][QR]                ← the relationship's toolbar
/// ```
///
/// - **The header is the profile's** (`ProfileHeaderView`): it has no action
///   row (#2475), its actions are this sheet's bars. A change to the
///   profile's header shows here too.
/// - **The toolbar is someone else's profile's** (`ProfileRelationToolbar`,
///   #2475): one source, so the card and the page draw one relationship the
///   same way.
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
    let imagePipeline: ImagePipeline
    let shareTargeting: (any ProfileShareTargeting)?
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
        viewModel.onActionResult = { [weak self] result in self?.relationActions.render(result) }
        viewModel.onUndoable = { [weak self] action in self?.relationActions.presentUndoable(action) }
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

    // MARK: - Share, report, block and the outcomes

    /// The page's own (`ProfileRelationActions`, #2522): share, copy link,
    /// report, block, the commands' outcomes and the Undo toast, anchored on
    /// this card's view and toasting a block from its presenter.
    private(set) lazy var relationActions = ProfileRelationActions(host: self)
    var actionAnchor: UIView { view }
    var blockToastSource: UIViewController { presentingViewController ?? self }

    // MARK: - The bars

    /// The card is a sheet: its gate is found through its presenter's
    /// children (`firstController(as:)`, #2565).
    private var isGuest: Bool { MemberGates.isGuest(self) }

    /// The bell stands while the viewer follows, for a member — the one
    /// rule the profile's toolbar reads too (`ProfileRelationControl`, #2302).
    var showsMuteBell: Bool {
        Self.showsMuteBell(followButton: followButtonState, canMute: viewModel.canMute, isGuest: isGuest)
    }

    /// `ProfileRelationControl.showsMuteBell`. Pure, for tests.
    nonisolated static func showsMuteBell(
        followButton: ProfileViewModel.FollowButton, canMute: Bool, isGuest: Bool
    ) -> Bool {
        ProfileRelationControl.showsMuteBell(followButton: followButton, canMute: canMute, isGuest: isGuest)
    }

    /// The toolbar's items for a relationship — someone else's profile's
    /// rule (`ProfileRelationToolbar.items`, one source, #2475). Pure, for
    /// tests.
    nonisolated static func toolbarItems(
        for followButton: ProfileViewModel.FollowButton, showsBell: Bool = true, showsQR: Bool = true
    ) -> [ProfileRelationToolbar.Item] {
        ProfileRelationToolbar.items(for: followButton, showsBell: showsBell, showsQR: showsQR)
    }

    /// Whether the top bar carries the ••• menu: everywhere but the viewer's
    /// own profile, which only opens it. Pure, for tests.
    nonisolated static func showsMoreMenu(for followButton: ProfileViewModel.FollowButton) -> Bool {
        followButton != .edit
    }

    /// The ••• menu's identity, top left, across rebuilds.
    nonisolated static let moreIdentifier = "profileCard.more"

    /// What the bars last showed: they are applied only when it changes, so
    /// a phase or a refresh that leaves them alone does not touch them.
    private struct BarState: Equatable {
        var muteScopes: MuteScopes
        var more: Bool
        var toolbar: [ProfileRelationToolbar.Item]
    }

    private var shownBars: BarState?

    /// The relationship's toolbar — someone else's profile's own
    /// (`ProfileRelationToolbar`, #2475) — and the ••• menu, kept by
    /// identifier (#2331): an item that stays is the same instance.
    private lazy var toolbar = ProfileRelationToolbar(actions: .init(
        follow: { [weak self] in self?.followTapped() },
        message: { [weak self] in self?.messageTapped() },
        qrCode: { [weak self] in self?.relationActions.presentShareSheet() },
        openProfile: { [weak self] in self?.infoTapped() },
        muteScopes: { [weak self] in self?.viewModel.muteScopes ?? .none },
        toggleMute: { [weak self] scope in self?.viewModel.toggleMute(scope) }
    ))
    private let leadingStore = BarItemStore()

    /// ⚠️ ONLY THE ITEM THAT CHANGED MOVES (#2331, the owner 2026-11-11):
    /// the toolbar keeps its items by identifier and dresses them in place
    /// (`ProfileRelationToolbar`), and the bar is handed the items only when
    /// the list changes. No animation of ours (#1672).
    private func applyBars() {
        let state = BarState(
            muteScopes: viewModel.muteScopes,
            more: Self.showsMoreMenu(for: followButtonState),
            toolbar: Self.toolbarItems(
                for: followButtonState, showsBell: showsMuteBell,
                showsQR: viewModel.shareCard != nil || viewModel.profile == nil
            )
        )
        guard state != shownBars else { return }
        shownBars = state
        let animated = view.window != nil
        // The ••• menu, top left (#1562): its rows are read as it opens.
        let leading: [UIBarButtonItem] = state.more ? [leadingStore.item(Self.moreIdentifier) {
            BarItems.icon(
                id: Self.moreIdentifier, image: UIImage(systemName: "ellipsis"), label: "More", menu: makeMoreMenu()
            )
        }] : []
        leadingStore.apply(leading: leading, to: navigationItem, animated: animated)

        toolbar.apply(state.toolbar, muteScopes: state.muteScopes, to: self, animated: animated)
    }

    /// The item taking the toolbar's free width, its view — what a test reads.
    var wideLabel: StretchedBarLabel? { relationToolbarWideLabel }

    #if DEBUG
    /// How many times the toolbar and the top bar's leading run were handed
    /// their items. Tests.
    var debugToolbarWrites: Int { toolbar.debugWrites }
    var debugLeadingWrites: Int { leadingStore.debugWrites }
    #endif

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
        // Following has left the toolbar (#1562): Unfollow leads the menu —
        // the profile's builder, so the card and the page say it alike (#2302).
        ProfileMenuBuilder.moreMenuElements(
            ProfileMenuBuilder.MoreMenuState(
                canShare: viewModel.shareCard != nil,
                mapPin: viewModel.mapPinButton,
                canModerate: viewModel.canModerate,
                isGuest: isGuest,
                canRestrict: viewModel.canRestrict,
                isRestricted: viewModel.isRestricted,
                isBlocked: viewModel.isBlocked,
                canClearHistory: false,
                isFollowing: followButtonState == .following
            ),
            handlers: ProfileMenuBuilder.MoreMenuHandlers(
                share: { [weak self] in self?.relationActions.presentShareSheet() },
                copyLink: { [weak self] in self?.relationActions.copyProfileLink() },
                toggleMapCategory: { [weak self] category in self?.viewModel.toggleMapCategory(category) },
                report: { [weak self] in self?.relationActions.presentReportReasons() },
                toggleRestrict: { [weak self] in self?.viewModel.toggleRestrict() },
                unblock: { [weak self] in self?.viewModel.unblock() },
                confirmBlock: { [weak self] in self?.relationActions.confirmBlock() },
                clearHistory: {},
                unfollow: { [weak self] in
                    // Only while still followed: a menu opened before a
                    // change must not follow back.
                    guard self?.followButtonState == .following else { return }
                    self?.followTapped()
                }
            )
        )
    }

    /// Wears the relationship on the header's avatar (#2014): the
    /// profile's own mapping (`ProfileRelationActions.applyRelationMark`).
    private func applyRelationMark() { relationActions.applyRelationMark() }

    // MARK: - Actions

    func followTapped() {
        MemberGates.perform(.follow(handle: viewModel.profile?.handle), from: self) { [weak self] in
            // On at the optimistic flip; off is silent (#1886).
            if self?.viewModel.toggleFollow() == true { Haptics.play(.toggleOn) }
        }
    }

    /// The conversation opens on the presenter's stack: the card goes first.
    func messageTapped() {
        MemberGates.perform(.message(handle: viewModel.profile?.handle), from: self) { [weak self] in
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

extension ProfileCardViewController: ProfileRelationActionsHost {}
