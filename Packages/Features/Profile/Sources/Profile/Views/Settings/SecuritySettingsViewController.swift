import DesignSystem
import UIKit

/// Settings → Security and Login: the Security Checkup, Change Password
/// (#382), Two-Step Sign-In with its backup codes (#383), where the account
/// is signed in and the two ways out — one other device, or every device at
/// once (#384) — and App Lock (#418).
///
/// Passkeys are listed under Coming Soon (#405): the server has them
/// (backend #808), the app's contracts and associated domain don't yet.
final class SecuritySettingsViewController: UIViewController {
    private enum Section: Hashable {
        case checkup, password, sessions, global, appLock, comingSoon
    }

    enum Item: Hashable {
        case checkup
        case changePassword
        case twoStep
        case requireLock
        case lockDelay
        case session(AccountSession)
        /// A session-shaped bone while the list loads (charter P8).
        case skeleton(Int)
        case failed
        case logOutEverywhere
        case planned(String)
    }

    private static let planned = ["Passkeys", "New sign-in alerts"]

    private let viewModel: SecuritySettingsViewModel
    private let onSignedOutEverywhere: () -> Void
    private let authenticator: any DeviceAuthenticating
    private let makeCheckup: (() -> UIViewController)?
    private let makeChangePassword: (() -> UIViewController)?
    private let makeTwoStep: (() -> UIViewController)?
    private var collectionView: UICollectionView!
    private var dataSource: UICollectionViewDiffableDataSource<Section, Item>!
    /// Whether the sessions section last drew bones: the swap away from them
    /// cross-fades (P10), every other redraw is plain.
    private var isShowingSkeleton = false

    init(
        viewModel: SecuritySettingsViewModel,
        onSignedOutEverywhere: @escaping () -> Void,
        authenticator: any DeviceAuthenticating = DeviceAuthenticator(),
        makeCheckup: (() -> UIViewController)? = nil,
        makeChangePassword: (() -> UIViewController)? = nil,
        makeTwoStep: (() -> UIViewController)? = nil
    ) {
        self.viewModel = viewModel
        self.makeTwoStep = makeTwoStep
        self.onSignedOutEverywhere = onSignedOutEverywhere
        self.authenticator = authenticator
        self.makeCheckup = makeCheckup
        self.makeChangePassword = makeChangePassword
        super.init(nibName: nil, bundle: nil)
        title = SettingsSection.security.title
        hidesBottomBarWhenPushed = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidLoad() {
        super.viewDidLoad()
        navigationItem.largeTitleDisplayMode = .never
        configureCollectionView()
        configureDataSource()
        viewModel.onChange = { [weak self] in self?.applySnapshot() }
        applySnapshot()
        Task { await viewModel.load() }
    }

    /// Coming back (from Change Password, which can log the other devices
    /// out, or from the checkup) re-reads the sessions. The list on screen
    /// stays until the new one arrives, so nothing flashes.
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        if hasAppeared { Task { await viewModel.load() } }
        hasAppeared = true
    }

    private var hasAppeared = false

    // MARK: - Setup

    private func configureCollectionView() {
        var config = UICollectionLayoutListConfiguration(appearance: .insetGrouped)
        config.headerMode = .supplementary
        config.footerMode = .supplementary
        config.trailingSwipeActionsConfigurationProvider = { [weak self] indexPath in
            self?.swipeActions(at: indexPath)
        }
        collectionView = UICollectionView(
            frame: view.bounds,
            collectionViewLayout: UICollectionViewCompositionalLayout.list(using: config)
        )
        collectionView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        collectionView.prefersSoftTopEdge()
        collectionView.delegate = self
        view.addSubview(collectionView)
    }

    private func configureDataSource() {
        let registration = UICollectionView.CellRegistration<UICollectionViewListCell, Item> { [weak self] cell, _, item in
            Self.configure(cell, for: item)
            self?.configureOwnRow(cell, for: item)
        }
        let skeletonRegistration = UICollectionView.CellRegistration<SettingsSkeletonRowCell, Int> { cell, _, index in
            cell.configure(redacting: Self.sessionPlaceholder(index))
        }
        dataSource = UICollectionViewDiffableDataSource<Section, Item>(collectionView: collectionView) { collectionView, indexPath, item in
            if case .skeleton(let index) = item {
                return collectionView.dequeueConfiguredReusableCell(using: skeletonRegistration, for: indexPath, item: index)
            }
            return collectionView.dequeueConfiguredReusableCell(using: registration, for: indexPath, item: item)
        }
        let header = UICollectionView.SupplementaryRegistration<UICollectionViewListCell>(
            elementKind: UICollectionView.elementKindSectionHeader
        ) { [weak self] view, _, indexPath in
            var content = UIListContentConfiguration.header()
            content.text = self?.dataSource.sectionIdentifier(for: indexPath.section).flatMap(Self.headerText)
            view.contentConfiguration = content
        }
        let footer = UICollectionView.SupplementaryRegistration<UICollectionViewListCell>(
            elementKind: UICollectionView.elementKindSectionFooter
        ) { [weak self] view, _, indexPath in
            var content = UIListContentConfiguration.footer()
            content.text = self?.dataSource.sectionIdentifier(for: indexPath.section).flatMap(Self.footerText)
            view.contentConfiguration = content
        }
        dataSource.supplementaryViewProvider = { collectionView, kind, indexPath in
            kind == UICollectionView.elementKindSectionHeader
                ? collectionView.dequeueConfiguredReusableSupplementary(using: header, for: indexPath)
                : collectionView.dequeueConfiguredReusableSupplementary(using: footer, for: indexPath)
        }
    }

    private static func headerText(_ section: Section) -> String? {
        switch section {
        case .checkup: nil
        case .password: nil
        case .sessions: "Where You're Logged In"
        case .global: nil
        case .appLock: "App Lock"
        case .comingSoon: "Coming Soon"
        }
    }

    private static func footerText(_ section: Section) -> String? {
        switch section {
        case .checkup: nil
        case .password: nil
        case .sessions: "Tap another device to log it out."
        case .global: "Ends every session, including this one. You'll need to log in again."
        case .appLock: "Applies to this iPhone. When it's on, opening the app asks for Face ID or your passcode, and the app is hidden in the app switcher."
        case .comingSoon: "These need a server update and aren't available yet."
        }
    }

    // MARK: - Snapshot

    private func applySnapshot() {
        var snapshot = NSDiffableDataSourceSnapshot<Section, Item>()
        if makeCheckup != nil {
            snapshot.appendSections([.checkup])
            snapshot.appendItems([.checkup], toSection: .checkup)
        }
        let passwordRows: [Item] = (makeChangePassword != nil ? [.changePassword] : []) + (makeTwoStep != nil ? [.twoStep] : [])
        if !passwordRows.isEmpty {
            snapshot.appendSections([.password])
            snapshot.appendItems(passwordRows, toSection: .password)
        }
        snapshot.appendSections([.sessions, .global, .appLock, .comingSoon])
        let sessionItems = Self.sessionItems(for: viewModel.phase)
        snapshot.appendItems(sessionItems, toSection: .sessions)
        snapshot.appendItems([.logOutEverywhere], toSection: .global)
        snapshot.appendItems(AppLockPreference.isOn ? [.requireLock, .lockDelay] : [.requireLock], toSection: .appLock)
        snapshot.appendItems(Self.planned.map(Item.planned), toSection: .comingSoon)

        let wasShowingSkeleton = isShowingSkeleton
        isShowingSkeleton = viewModel.phase == .loading
        if wasShowingSkeleton, !isShowingSkeleton {
            collectionView.crossfadeFromSkeleton { [dataSource, snapshot] in
                dataSource?.apply(snapshot, animatingDifferences: false)
            }
        } else {
            dataSource.apply(snapshot, animatingDifferences: view.window != nil)
        }
    }

    /// The sessions section's rows: bones the shape of a session while the
    /// list loads — never a spinner (P8) — the retry row after a failed first
    /// load, the sessions otherwise.
    static func sessionItems(for phase: SecuritySettingsViewModel.Phase) -> [Item] {
        switch phase {
        case .loading: [.skeleton(0), .skeleton(1)]
        case .failed: [.failed]
        case .loaded(let sessions): sessions.map(Item.session)
        }
    }

    /// A session row with sample words; only the bones' widths come from them.
    private static func sessionPlaceholder(_ index: Int) -> UIListContentConfiguration {
        var content = UIListContentConfiguration.subtitleCell()
        content.text = index.isMultiple(of: 2) ? "iPhone" : "Web browser"
        content.secondaryText = index.isMultiple(of: 2) ? "iOS 27.0 · This device" : "Signed in 3 days ago"
        content.image = UIImage(systemName: "iphone")
        return content
    }

    // MARK: - Rows

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter
    }()

    /// "iOS 27.0 · This device", "Web browser · Signed in 3 days ago".
    static func sessionSubtitle(_ session: AccountSession, now: Date = Date()) -> String {
        var parts: [String] = []
        if let detail = session.device.detail { parts.append(detail) }
        if session.isCurrent {
            parts.append("This device")
        } else if let signedInAt = session.signedInAt {
            parts.append("Signed in \(relativeFormatter.localizedString(for: signedInAt, relativeTo: now))")
        }
        return parts.joined(separator: " · ")
    }

    private static func symbol(for kind: SessionDevice.Kind) -> String {
        switch kind {
        case .iPhone: "iphone"
        case .iPad: "ipad"
        case .mac: "laptopcomputer"
        case .windows: "pc"
        case .android: "candybarphone"
        case .unknown: "questionmark.circle"
        }
    }

    private static func configure(_ cell: UICollectionViewListCell, for item: Item) {
        cell.accessories = []
        cell.contentView.subviews.filter { $0.tag == lockControlTag }.forEach { $0.removeFromSuperview() }
        switch item {
        case .checkup, .requireLock, .lockDelay:
            break
        case .changePassword:
            var content = UIListContentConfiguration.cell()
            content.text = "Change Password"
            content.image = UIImage(systemName: "key")
            content.imageProperties.tintColor = .label
            cell.contentConfiguration = content
            cell.accessories = [.disclosureIndicator()]
        case .twoStep:
            var content = UIListContentConfiguration.cell()
            content.text = "Two-Step Sign-In"
            content.image = UIImage(systemName: "lock.shield")
            content.imageProperties.tintColor = .label
            cell.contentConfiguration = content
            cell.accessories = [.disclosureIndicator()]
        case .session(let session):
            var content = UIListContentConfiguration.subtitleCell()
            content.text = session.device.title
            content.secondaryText = sessionSubtitle(session)
            content.secondaryTextProperties.color = session.isCurrent ? .systemGreen : .secondaryLabel
            content.image = UIImage(systemName: symbol(for: session.device.kind))
            content.imageProperties.tintColor = .label
            cell.contentConfiguration = content
        case .skeleton:
            // Drawn by `SettingsSkeletonRowCell`.
            break
        case .failed:
            var content = UIListContentConfiguration.cell()
            content.text = "Couldn't load your sessions. Tap to try again."
            content.textProperties.color = .secondaryLabel
            cell.contentConfiguration = content
        case .logOutEverywhere:
            var content = UIListContentConfiguration.cell()
            content.text = "Log Out of All Devices"
            content.textProperties.color = .systemRed
            cell.contentConfiguration = content
        case .planned(let title):
            var content = UIListContentConfiguration.cell()
            content.text = title
            content.textProperties.color = .secondaryLabel
            cell.contentConfiguration = content
        }
    }

    // MARK: - App Lock and checkup rows

    private static let lockControlTag = 0x10C4

    /// The rows that need the screen (the authenticator, the lock switch).
    private func configureOwnRow(_ cell: UICollectionViewListCell, for item: Item) {
        switch item {
        case .checkup:
            var content = UIListContentConfiguration.cell()
            content.text = "Security Checkup"
            content.image = UIImage(systemName: "checkmark.shield")
            content.imageProperties.tintColor = .label
            cell.contentConfiguration = content
            cell.accessories = [.disclosureIndicator()]
        case .requireLock:
            let method = authenticator.availableMethod()
            var content = UIListContentConfiguration.subtitleCell()
            content.text = "Require \(method ?? "Face ID")"
            content.secondaryText = method == nil ? "Set up Face ID or a passcode in iOS Settings first." : nil
            content.secondaryTextProperties.color = .secondaryLabel
            content.image = UIImage(systemName: "lock")
            content.imageProperties.tintColor = .label
            cell.contentConfiguration = content
            let toggle = UISwitch()
            toggle.isOn = AppLockPreference.isOn
            toggle.isEnabled = method != nil || AppLockPreference.isOn
            toggle.addAction(UIAction { [weak self] action in
                guard let toggle = action.sender as? UISwitch else { return }
                self?.setAppLock(toggle.isOn, toggle: toggle)
            }, for: .valueChanged)
            cell.accessories = [.customView(configuration: .init(customView: toggle, placement: .trailing(displayed: .always)))]
        case .lockDelay:
            cell.contentConfiguration = nil
            let options = AppLockPreference.Delay.allCases
            let control = UISegmentedControl(items: options.map(\.title))
            control.selectedSegmentIndex = options.firstIndex(of: AppLockPreference.delay) ?? 0
            control.accessibilityLabel = "Lock after"
            control.addAction(UIAction { action in
                guard let control = action.sender as? UISegmentedControl else { return }
                AppLockPreference.delay = options[control.selectedSegmentIndex]
            }, for: .valueChanged)
            control.tag = Self.lockControlTag
            control.translatesAutoresizingMaskIntoConstraints = false
            cell.contentView.addSubview(control)
            let margins = cell.contentView.layoutMarginsGuide
            NSLayoutConstraint.activate([
                control.leadingAnchor.constraint(equalTo: margins.leadingAnchor),
                control.trailingAnchor.constraint(equalTo: margins.trailingAnchor),
                control.topAnchor.constraint(equalTo: cell.contentView.topAnchor, constant: 10),
                control.bottomAnchor.constraint(equalTo: cell.contentView.bottomAnchor, constant: -10)
            ])
        default:
            break
        }
    }

    /// Turning App Lock on or off asks for Face ID / the passcode first, so
    /// someone holding an unlocked phone can't switch it off.
    private func setAppLock(_ isOn: Bool, toggle: UISwitch) {
        Task { [weak self] in
            guard let self else { return }
            let confirmed = await authenticator.authenticate(
                reason: isOn ? "Turn on App Lock" : "Turn off App Lock"
            )
            if confirmed {
                AppLockPreference.isOn = isOn
            } else {
                toggle.setOn(!isOn, animated: true)
            }
            applySnapshot()
        }
    }

    // MARK: - Actions

    private func swipeActions(at indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        guard case .session(let session) = dataSource.itemIdentifier(for: indexPath), !session.isCurrent else { return nil }
        let action = UIContextualAction(style: .destructive, title: "Log Out") { [weak self] _, _, done in
            self?.revoke(session)
            done(true)
        }
        return UISwipeActionsConfiguration(actions: [action])
    }

    private func confirmRevoke(_ session: AccountSession) {
        let sheet = UIAlertController(
            title: "Log out of \(session.device.title)?",
            message: "That device will need to log in again.",
            preferredStyle: .actionSheet
        )
        sheet.addAction(UIAlertAction(title: "Log Out", style: .destructive) { [weak self] _ in
            self?.revoke(session)
        })
        sheet.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        presentSheet(sheet)
    }

    private func revoke(_ session: AccountSession) {
        Task { [weak self] in
            guard let self else { return }
            do {
                try await viewModel.revoke(session)
            } catch {
                presentInfo("Couldn't log out \(session.device.title). Try again.")
            }
        }
    }

    private func confirmLogOutEverywhere() {
        let sheet = UIAlertController(
            title: "Log out of all devices?",
            message: "Every session ends, including this one.",
            preferredStyle: .actionSheet
        )
        sheet.addAction(UIAlertAction(title: "Log Out of All Devices", style: .destructive) { [weak self] _ in
            self?.logOutEverywhere()
        })
        sheet.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        presentSheet(sheet)
    }

    private func logOutEverywhere() {
        Task { [weak self] in
            guard let self else { return }
            do {
                try await viewModel.revokeAll()
                onSignedOutEverywhere()
            } catch {
                presentInfo("Couldn't log out of all devices. Try again.")
            }
        }
    }

    private func presentSheet(_ sheet: UIAlertController) {
        if let popover = sheet.popoverPresentationController {
            popover.sourceView = view
            popover.sourceRect = CGRect(x: view.bounds.midX, y: view.bounds.maxY - 60, width: 0, height: 0)
            popover.permittedArrowDirections = []
        }
        present(sheet, animated: true)
    }

    private func presentInfo(_ message: String) {
        let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }
}

// MARK: - Selection

extension SecuritySettingsViewController: UICollectionViewDelegate {
    func collectionView(_ collectionView: UICollectionView, shouldHighlightItemAt indexPath: IndexPath) -> Bool {
        switch dataSource.itemIdentifier(for: indexPath) {
        case .session(let session): !session.isCurrent
        case .failed, .logOutEverywhere, .checkup, .changePassword, .twoStep: true
        case .skeleton, .planned, .requireLock, .lockDelay, nil: false
        }
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        switch dataSource.itemIdentifier(for: indexPath) {
        case .session(let session) where !session.isCurrent:
            confirmRevoke(session)
        case .failed:
            Task { await viewModel.load() }
        case .logOutEverywhere:
            confirmLogOutEverywhere()
        case .checkup:
            if let checkup = makeCheckup?() {
                navigationController?.pushViewController(checkup, animated: true)
            }
        case .changePassword:
            if let screen = makeChangePassword?() {
                navigationController?.pushViewController(screen, animated: true)
            }
        case .twoStep:
            if let screen = makeTwoStep?() {
                navigationController?.pushViewController(screen, animated: true)
            }
        default:
            break
        }
    }
}
