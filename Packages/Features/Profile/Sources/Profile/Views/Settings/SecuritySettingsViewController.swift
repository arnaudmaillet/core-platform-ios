import DesignSystem
import UIKit

/// Settings → Security and Login: where the account is signed in, and the
/// two ways out — one other device, or every device at once (#384).
///
/// Change password and two-factor are listed under Coming Soon rather than
/// offered: their `account.v1` RPCs take a server-side hash and an encrypted
/// seed, internal calls for an edge service the app cannot stand in for
/// (#382, #383).
final class SecuritySettingsViewController: UIViewController {
    private enum Section: Hashable {
        case sessions, global, comingSoon
    }

    private enum Item: Hashable {
        case session(AccountSession)
        case loading
        case failed
        case logOutEverywhere
        case planned(String)
    }

    private static let planned = ["Change password", "Two-factor authentication", "Backup codes and passkeys"]

    private let viewModel: SecuritySettingsViewModel
    private let onSignedOutEverywhere: () -> Void
    private var collectionView: UICollectionView!
    private var dataSource: UICollectionViewDiffableDataSource<Section, Item>!

    init(viewModel: SecuritySettingsViewModel, onSignedOutEverywhere: @escaping () -> Void) {
        self.viewModel = viewModel
        self.onSignedOutEverywhere = onSignedOutEverywhere
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
        collectionView.prefersClearTopEdge()
        collectionView.delegate = self
        view.addSubview(collectionView)
    }

    private func configureDataSource() {
        let registration = UICollectionView.CellRegistration<UICollectionViewListCell, Item> { cell, _, item in
            Self.configure(cell, for: item)
        }
        dataSource = UICollectionViewDiffableDataSource<Section, Item>(collectionView: collectionView) { collectionView, indexPath, item in
            collectionView.dequeueConfiguredReusableCell(using: registration, for: indexPath, item: item)
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
        case .sessions: "Where You're Logged In"
        case .global: nil
        case .comingSoon: "Coming Soon"
        }
    }

    private static func footerText(_ section: Section) -> String? {
        switch section {
        case .sessions: "Tap another device to log it out."
        case .global: "Ends every session, including this one. You'll need to log in again."
        case .comingSoon: "These need a server update and aren't available yet."
        }
    }

    // MARK: - Snapshot

    private func applySnapshot() {
        var snapshot = NSDiffableDataSourceSnapshot<Section, Item>()
        snapshot.appendSections([.sessions, .global, .comingSoon])
        switch viewModel.phase {
        case .loading:
            snapshot.appendItems([.loading], toSection: .sessions)
        case .failed:
            snapshot.appendItems([.failed], toSection: .sessions)
        case .loaded(let sessions):
            snapshot.appendItems(sessions.map(Item.session), toSection: .sessions)
        }
        snapshot.appendItems([.logOutEverywhere], toSection: .global)
        snapshot.appendItems(Self.planned.map(Item.planned), toSection: .comingSoon)
        dataSource.apply(snapshot, animatingDifferences: view.window != nil)
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
        switch item {
        case .session(let session):
            var content = UIListContentConfiguration.subtitleCell()
            content.text = session.device.title
            content.secondaryText = sessionSubtitle(session)
            content.secondaryTextProperties.color = session.isCurrent ? .systemGreen : .secondaryLabel
            content.image = UIImage(systemName: symbol(for: session.device.kind))
            content.imageProperties.tintColor = .label
            cell.contentConfiguration = content
        case .loading:
            var content = UIListContentConfiguration.cell()
            content.text = "Loading…"
            content.textProperties.color = .secondaryLabel
            cell.contentConfiguration = content
            let spinner = UIActivityIndicatorView(style: .medium)
            spinner.startAnimating()
            cell.accessories = [.customView(configuration: .init(customView: spinner, placement: .trailing()))]
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
        case .failed, .logOutEverywhere: true
        case .loading, .planned, nil: false
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
        default:
            break
        }
    }
}
