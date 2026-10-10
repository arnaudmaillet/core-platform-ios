import DesignSystem
import UIKit

/// One line of the security checkup.
struct SecurityCheckupItem: Hashable, Sendable {
    enum State: Hashable, Sendable {
        case done
        case recommended
        /// The app can't do this yet (needs a backend contract).
        case unavailable
        /// Advice with nothing to tick: not counted, it points somewhere.
        case info
        /// Couldn't be read (#799): a failed line with retry, never counted
        /// as done — and named in the summary so it can't read all clear.
        case failed
    }

    let id: String
    let title: String
    let detail: String
    let symbolName: String
    let state: State
}

/// What the checkup recommends, from what the app knows. Pure, so the rules
/// are pinned by tests. The password is advice (it can be changed, but the
/// app can't judge how strong it is); two-factor is listed as unavailable
/// rather than hidden: their contracts are internal today (#382, #383), and a
/// checkup that skipped them would look complete when it isn't.
///
/// The same goes for a read that failed (#799): its line stays, as a failed
/// line. Only a source the screen doesn't have (nil) or a read still running
/// leaves a line out.
enum SecurityCheckup {
    static let failedAccountTitle = "Couldn't load your email and phone. Tap to try again."
    static let failedSessionsTitle = "Couldn't load your logged-in devices. Tap to try again."

    static func items(
        account: Loadable<AccountDetails>?, sessionCount: Loadable<Int>?, appLockOn: Bool, lockMethod: String?
    ) -> [SecurityCheckupItem] {
        var items: [SecurityCheckupItem] = []
        if case .failed = account {
            items.append(SecurityCheckupItem(
                id: "account", title: failedAccountTitle, detail: "", symbolName: "envelope", state: .failed
            ))
        }
        if let account = account?.content {
            items.append(SecurityCheckupItem(
                id: "email",
                title: account.emailVerified ? "Email verified" : "Verify your email",
                detail: account.emailVerified
                    ? "\(account.email) can recover this account."
                    : "Verifying \(account.email) lets you recover the account if you lose access.",
                symbolName: "envelope",
                state: account.emailVerified ? .done : .recommended
            ))
            let hasPhone = !account.phone.isEmpty
            items.append(SecurityCheckupItem(
                id: "phone",
                title: hasPhone && account.phoneVerified ? "Phone verified" : (hasPhone ? "Verify your phone" : "Add a phone number"),
                detail: hasPhone
                    ? (account.phoneVerified ? "A second way to recover the account." : "A verified number is a second way back into the account.")
                    : "Adding a number isn't available in the app yet.",
                symbolName: "phone",
                state: hasPhone && account.phoneVerified ? .done : (hasPhone ? .recommended : .unavailable)
            ))
        }
        if case .failed = sessionCount {
            items.append(SecurityCheckupItem(
                id: "sessions", title: failedSessionsTitle, detail: "", symbolName: "laptopcomputer.and.iphone", state: .failed
            ))
        }
        if let sessionCount = sessionCount?.content {
            items.append(SecurityCheckupItem(
                id: "sessions",
                title: sessionCount <= 1 ? "Only this device is logged in" : "Review \(sessionCount) logged-in devices",
                detail: sessionCount <= 1
                    ? "No other device has access to this account."
                    : "Log out any device you don't recognise.",
                symbolName: "laptopcomputer.and.iphone",
                state: sessionCount <= 1 ? .done : .recommended
            ))
        }
        let method = lockMethod ?? "Face ID"
        items.append(SecurityCheckupItem(
            id: "appLock",
            title: appLockOn ? "App Lock is on" : "Turn on App Lock",
            detail: appLockOn
                ? "\(method) is needed to open the app on this iPhone."
                : "Require \(method) to open the app, so someone holding your phone can't.",
            symbolName: "lock",
            state: appLockOn ? .done : (lockMethod == nil ? .unavailable : .recommended)
        ))
        items.append(SecurityCheckupItem(
            id: "password", title: "Password",
            detail: "Change it from Security and Login if you think someone else knows it.",
            symbolName: "key", state: .info
        ))
        items.append(SecurityCheckupItem(
            id: "twoFactor", title: "Two-factor authentication",
            detail: "Two-factor authentication isn't available in the app yet.",
            symbolName: "lock.shield", state: .unavailable
        ))
        return items
    }

    /// "2 of 4 done" over what the viewer can act on; ", 1 couldn't be
    /// checked" when a read failed, so a partial checkup never reads as a
    /// complete one.
    static func summary(_ items: [SecurityCheckupItem]) -> String {
        let actionable = items.filter { $0.state == .done || $0.state == .recommended }
        let done = actionable.filter { $0.state == .done }.count
        let failed = items.filter { $0.state == .failed }.count
        let tally = "\(done) of \(actionable.count) done"
        return failed == 0 ? tally : "\(tally), \(failed) couldn't be checked"
    }
}

/// Settings → Security and Login → Security Checkup (#418): one screen that
/// says what is protecting the account and what isn't. A recommended item
/// that lives on the Security page (devices, App Lock) takes the viewer back
/// there.
final class SecurityCheckupViewController: UIViewController {
    private let viewModel: SecurityCheckupViewModel
    private let authenticator: any DeviceAuthenticating
    private var items: [SecurityCheckupItem] = []
    private var collectionView: UICollectionView!
    private var dataSource: UICollectionViewDiffableDataSource<Int, SecurityCheckupItem>!

    init(account: (any AccountProviding)?, sessions: (any AccountSessionsManaging)?, authenticator: any DeviceAuthenticating) {
        viewModel = SecurityCheckupViewModel(account: account, sessions: sessions)
        self.authenticator = authenticator
        super.init(nibName: nil, bundle: nil)
        title = "Security Checkup"
        hidesBottomBarWhenPushed = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidLoad() {
        super.viewDidLoad()
        navigationItem.largeTitleDisplayMode = .never
        var config = UICollectionLayoutListConfiguration(appearance: .insetGrouped)
        config.headerMode = .supplementary
        collectionView = UICollectionView(
            frame: view.bounds,
            collectionViewLayout: UICollectionViewCompositionalLayout.list(using: config)
        )
        collectionView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        collectionView.prefersSoftTopEdge()
        collectionView.delegate = self
        view.addSubview(collectionView)

        let registration = UICollectionView.CellRegistration<UICollectionViewListCell, SecurityCheckupItem> { cell, _, item in
            guard item.state != .failed else {
                // The failed-row style every Settings screen uses (#799).
                var content = UIListContentConfiguration.cell()
                content.text = item.title
                content.textProperties.color = .secondaryLabel
                cell.contentConfiguration = content
                cell.accessories = []
                return
            }
            var content = UIListContentConfiguration.subtitleCell()
            content.text = item.title
            content.secondaryText = item.detail
            content.secondaryTextProperties.color = .secondaryLabel
            content.secondaryTextProperties.numberOfLines = 0
            content.image = UIImage(systemName: item.symbolName)
            content.imageProperties.tintColor = item.state == .unavailable ? .secondaryLabel : .label
            if item.state == .unavailable { content.textProperties.color = .secondaryLabel }
            cell.contentConfiguration = content
            let badge = UIImageView(image: UIImage(systemName: Self.badgeSymbol(item.state)))
            badge.tintColor = Self.badgeColor(item.state)
            cell.accessories = [.customView(configuration: .init(customView: badge, placement: .trailing(displayed: .always)))]
        }
        dataSource = UICollectionViewDiffableDataSource<Int, SecurityCheckupItem>(collectionView: collectionView) { collectionView, indexPath, item in
            collectionView.dequeueConfiguredReusableCell(using: registration, for: indexPath, item: item)
        }
        let header = UICollectionView.SupplementaryRegistration<UICollectionViewListCell>(
            elementKind: UICollectionView.elementKindSectionHeader
        ) { [weak self] view, _, _ in
            var content = UIListContentConfiguration.header()
            content.text = self.map { $0.items.isEmpty ? "Checking…" : SecurityCheckup.summary($0.items) }
            view.contentConfiguration = content
        }
        dataSource.supplementaryViewProvider = { collectionView, _, indexPath in
            collectionView.dequeueConfiguredReusableSupplementary(using: header, for: indexPath)
        }
        viewModel.onChange = { [weak self] in self?.rebuild() }
        apply()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        load()
    }

    private func load() {
        Task { [weak self] in
            guard let self else { return }
            await viewModel.load()
            rebuild()
        }
    }

    /// App Lock is read on the device, each time, beside the server's parts.
    private func rebuild() {
        items = SecurityCheckup.items(
            account: viewModel.account, sessionCount: viewModel.sessionCount,
            appLockOn: AppLockPreference.isOn, lockMethod: authenticator.availableMethod()
        )
        apply()
    }

    /// The failed line's retry: only that part is read again. A retry that
    /// fails again leaves the line and says so.
    private func retry(_ part: SecurityCheckupViewModel.Part) {
        Task { [weak self] in
            guard let self, await viewModel.reload(part) == false else { return }
            ToastView.present("Couldn't load this check", symbol: "exclamationmark.triangle", in: view)
        }
    }

    private func apply() {
        var snapshot = NSDiffableDataSourceSnapshot<Int, SecurityCheckupItem>()
        snapshot.appendSections([0])
        snapshot.appendItems(items)
        snapshot.reloadSections([0])
        dataSource.apply(snapshot, animatingDifferences: false)
    }

    private static func badgeSymbol(_ state: SecurityCheckupItem.State) -> String {
        switch state {
        case .done: "checkmark.circle.fill"
        case .recommended: "exclamationmark.circle.fill"
        case .unavailable: "minus.circle"
        case .info: "info.circle"
        case .failed: "exclamationmark.arrow.circlepath"
        }
    }

    private static func badgeColor(_ state: SecurityCheckupItem.State) -> UIColor {
        switch state {
        case .done: .systemGreen
        case .recommended: .systemOrange
        case .unavailable: .tertiaryLabel
        case .info, .failed: .secondaryLabel
        }
    }
}

extension SecurityCheckupViewController: UICollectionViewDelegate {
    func collectionView(_ collectionView: UICollectionView, shouldHighlightItemAt indexPath: IndexPath) -> Bool {
        guard let item = dataSource.itemIdentifier(for: indexPath) else { return false }
        return item.state == .failed
            || (item.state == .recommended && (item.id == "sessions" || item.id == "appLock")) || item.id == "password"
    }

    /// Devices, App Lock and Change Password live on the Security page this
    /// was pushed from; a failed line reads its part again.
    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        guard let item = dataSource.itemIdentifier(for: indexPath) else { return }
        if item.state == .failed {
            retry(item.id == "account" ? .account : .sessions)
            return
        }
        navigationController?.popViewController(animated: true)
    }
}
