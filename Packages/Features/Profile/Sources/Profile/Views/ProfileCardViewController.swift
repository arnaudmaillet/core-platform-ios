import CoreModels
import CoreNavigation
import DesignSystem
import MediaCore
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
        actions: Actions
    ) {
        self.viewModel = viewModel
        self.imagePipeline = imagePipeline
        self.shareTargeting = shareTargeting
        self.makeRelationshipsViewController = makeRelationshipsViewController
        self.actions = actions
        headerView = ProfileHeaderView(imagePipeline: imagePipeline)
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
        applyBars()
        viewModel.viewDidLoad()
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
        switch phase {
        case .loading:
            headerView.isHidden = false
            headerView.setRedacted(true)
        case .content(let model):
            headerView.isHidden = false
            headerView.configure(with: model)
            headerView.setRedacted(false, animated: view.window != nil)
        case .failed, .notFound:
            // A plain card, as the profile's plain page (#1406): no banner,
            // no header for no one.
            headerView.setRedacted(false)
            headerView.isHidden = viewModel.profile == nil
        }
        remeasure()
        applyBars()
    }

    private func render(_ result: ProfileViewModel.ActionResult) {
        switch result {
        case .blocked(let handle, let profileCount):
            let message = profileCount > 1 ? "Blocked \(handle) and \(profileCount - 1) more" : "Blocked \(handle)"
            Feedback.success(message, symbol: "hand.raised.fill", from: presentingViewController ?? self)
        case .unblocked(let handle):
            Feedback.success("Unblocked \(handle)", symbol: "hand.raised.slash.fill", from: self)
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
        case follow, following, requested, openProfile, message, more
    }

    nonisolated static func toolbarItems(for followButton: ProfileViewModel.FollowButton) -> [ToolbarItem] {
        switch followButton {
        case .follow: [.follow, .message, .more]
        case .following: [.following, .message, .more]
        case .requested: [.requested, .message, .more]
        // Not followable (#726): Message and the menu stay, as on the profile.
        case .unavailable: [.message, .more]
        // Unknown yet: what does not depend on the answer.
        case .hidden: [.message, .more]
        // The viewer's own profile, reached by id: nothing to do here but
        // open it.
        case .edit: [.openProfile]
        }
    }

    /// What the bars last showed: they are rebuilt only when it changes, so
    /// a phase or a refresh that leaves them alone does not redraw them.
    private struct BarState: Equatable {
        var bell: Bool
        var muted: Bool
        var qr: Bool
        var toolbar: [ToolbarItem]
    }

    private var shownBars: BarState?

    private func applyBars() {
        let state = BarState(
            bell: showsMuteBell, muted: !viewModel.muteScopes.isEmpty,
            qr: viewModel.shareCard != nil || viewModel.profile == nil,
            toolbar: Self.toolbarItems(for: followButtonState)
        )
        guard state != shownBars else { return }
        shownBars = state
        var leading: [UIBarButtonItem] = []
        if state.bell { leading.append(makeMuteBellItem()) }
        if state.qr {
            leading.append(UIBarButtonItem(
                image: UIImage(systemName: "qrcode"),
                primaryAction: UIAction { [weak self] _ in self?.presentShareSheet() }
            ))
            leading.last?.accessibilityLabel = "QR Code"
        }
        navigationItem.setLeftBarButtonItems(leading, animated: view.window != nil)

        var items: [UIBarButtonItem] = []
        for kind in state.toolbar {
            switch kind {
            case .follow:
                items.append(followItem(title: "Follow", prominent: true))
            case .following:
                items.append(followItem(title: "Following", prominent: false))
            case .requested:
                items.append(followItem(title: "Requested", prominent: false))
            case .openProfile:
                let open = UIBarButtonItem(title: "View Profile", primaryAction: UIAction { [weak self] _ in
                    self?.infoTapped()
                })
                open.style = .prominent
                items.append(open)
            case .message:
                items.append(UIBarButtonItem(title: "Message", primaryAction: UIAction { [weak self] _ in
                    self?.messageTapped()
                }))
            case .more:
                items.append(.flexibleSpace())
                let more = UIBarButtonItem(image: UIImage(systemName: "ellipsis"), menu: makeMoreMenu())
                more.accessibilityLabel = "More"
                items.append(more)
            }
        }
        setToolbarItems(items, animated: view.window != nil)
    }

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
    private func moreMenuElements() -> [UIMenuElement] {
        ProfileMenuBuilder.moreMenuElements(
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

    // MARK: - Actions

    private func followTapped() {
        MemberGates.perform(.follow(handle: viewModel.profile?.handle), from: gateSource) { [weak self] in
            self?.viewModel.toggleFollow()
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
        (navigationController ?? self).dismiss(animated: true)
    }

    /// Closes the card, then runs `body` — on the presenter's stack, which
    /// a push made while the sheet still stood would land behind it.
    private func closeThen(_ body: @escaping () -> Void) {
        let presented: UIViewController = navigationController ?? self
        guard presented.presentingViewController != nil else { return body() }
        presented.dismiss(animated: true, completion: body)
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
