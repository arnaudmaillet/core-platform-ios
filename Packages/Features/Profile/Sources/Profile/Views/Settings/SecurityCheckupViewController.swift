import DesignSystem
import UIKit

/// One line of the security checkup.
struct SecurityCheckupItem: Hashable, Sendable {
    enum State: Hashable, Sendable {
        case done
        case recommended
        /// The app can't do this yet (needs a backend contract).
        case unavailable
    }

    let id: String
    let title: String
    let detail: String
    let symbolName: String
    let state: State
}

/// What the checkup recommends, from what the app knows. Pure, so the rules
/// are pinned by tests. Password and two-factor are listed as unavailable
/// rather than hidden: their contracts are internal today (#382, #383), and a
/// checkup that skipped them would look complete when it isn't.
enum SecurityCheckup {
    static func items(account: AccountDetails?, sessionCount: Int?, appLockOn: Bool, lockMethod: String?) -> [SecurityCheckupItem] {
        var items: [SecurityCheckupItem] = []
        if let account {
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
        if let sessionCount {
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
            id: "password", title: "Strong password",
            detail: "Changing your password isn't available in the app yet.",
            symbolName: "key", state: .unavailable
        ))
        items.append(SecurityCheckupItem(
            id: "twoFactor", title: "Two-factor authentication",
            detail: "Two-factor authentication isn't available in the app yet.",
            symbolName: "lock.shield", state: .unavailable
        ))
        return items
    }

    /// "2 of 4 done" over what the viewer can act on.
    static func summary(_ items: [SecurityCheckupItem]) -> String {
        let actionable = items.filter { $0.state != .unavailable }
        let done = actionable.filter { $0.state == .done }.count
        return "\(done) of \(actionable.count) done"
    }
}

/// Settings → Security and Login → Security Checkup (#418): one screen that
/// says what is protecting the account and what isn't. A recommended item
/// that lives on the Security page (devices, App Lock) takes the viewer back
/// there.
final class SecurityCheckupViewController: UIViewController {
    private let account: (any AccountProviding)?
    private let sessions: (any AccountSessionsManaging)?
    private let authenticator: any DeviceAuthenticating
    private var items: [SecurityCheckupItem] = []
    private var collectionView: UICollectionView!
    private var dataSource: UICollectionViewDiffableDataSource<Int, SecurityCheckupItem>!

    init(account: (any AccountProviding)?, sessions: (any AccountSessionsManaging)?, authenticator: any DeviceAuthenticating) {
        self.account = account
        self.sessions = sessions
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
        apply()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        load()
    }

    private func load() {
        Task { [weak self] in
            guard let self else { return }
            let details = try? await account?.currentAccount()
            let count = try? await sessions?.activeSessions().count
            items = SecurityCheckup.items(
                account: details, sessionCount: count,
                appLockOn: AppLockPreference.isOn, lockMethod: authenticator.availableMethod()
            )
            apply()
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
        }
    }

    private static func badgeColor(_ state: SecurityCheckupItem.State) -> UIColor {
        switch state {
        case .done: .systemGreen
        case .recommended: .systemOrange
        case .unavailable: .tertiaryLabel
        }
    }
}

extension SecurityCheckupViewController: UICollectionViewDelegate {
    func collectionView(_ collectionView: UICollectionView, shouldHighlightItemAt indexPath: IndexPath) -> Bool {
        guard let item = dataSource.itemIdentifier(for: indexPath) else { return false }
        return item.state == .recommended && (item.id == "sessions" || item.id == "appLock")
    }

    /// Devices and App Lock live on the Security page this was pushed from.
    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        navigationController?.popViewController(animated: true)
    }
}
