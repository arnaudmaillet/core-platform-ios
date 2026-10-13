import CoreModels
import CoreNetworking
import DesignSystem
import MediaCore
import UIKit

/// Settings → Privacy → Activity and Discovery → Find Friends from Contacts
/// (#412). Explains before iOS asks for the address book, then lists the
/// profiles behind the contacts with the app's follow-button person row
/// (`RelationshipListCell`). Denied, limited, empty, offline and failed each
/// get their own state; a follow that fails says so through `Feedback`.
final class ContactFriendsViewController: UIViewController {
    private let viewModel: ContactFriendsViewModel
    private let imagePipeline: ImagePipeline?
    private var collectionView: UICollectionView!
    private var dataSource: UICollectionViewDiffableDataSource<Int, ProfileID>!
    private var rowsByID: [ProfileID: ContactFriendsViewModel.Row] = [:]
    private var isLimited = false

    init(viewModel: ContactFriendsViewModel, imagePipeline: ImagePipeline?) {
        self.viewModel = viewModel
        self.imagePipeline = imagePipeline
        super.init(nibName: nil, bundle: nil)
        title = Self.title
        hidesBottomBarWhenPushed = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // MARK: - Copy

    static let title = "Find Friends from Contacts"
    static let prePromptTitle = "Find Friends from Your Contacts"
    static let prePromptMessage = "See which of your contacts are here, and follow them. Their email addresses and phone numbers are turned into codes on your iPhone before they're checked, and nothing from your contacts is stored. People who turned off Find Me by Phone Number or Find Me by Email don't show up."
    static let deniedTitle = "Contacts Access Is Off"
    static let deniedMessage = "To find friends from your contacts, allow access to Contacts in Settings."
    static let emptyTitle = "No Contacts Found"
    static let emptyMessage = "None of your contacts are here yet, or they've chosen not to be found this way."
    static let limitedNote = "You've shared only some of your contacts. To check more, change access in Settings."
    static let dailyLimitMessage = "You've checked a lot of contacts today. Try again tomorrow."
    static let header = "From Your Contacts"

    /// The failed state's sentence: offline or slow when that is why.
    static func failureMessage(_ failure: ContactFriendsViewModel.Failure) -> String {
        switch failure {
        case .dailyLimit: dailyLimitMessage
        case .network(let reason): FailureCopy.message(for: reason, fallback: "Couldn't check your contacts. Try again.")
        }
    }

    /// The second line: the handle, and the name in the viewer's contacts
    /// when it says more than the profile's own.
    static func subtitle(for row: ContactFriendsViewModel.Row) -> String {
        guard let contact = row.contactName else { return "@\(row.handle)" }
        return "@\(row.handle) · \(contact)"
    }

    static func action(for row: ContactFriendsViewModel.Row) -> ProfileRelationshipsViewModel.RowAction {
        switch row.relation {
        case .viewer, .blocked: .inert
        case .notFollowing: .follow
        case .followedBy: .followBack
        case .following, .mutual: .following
        case .requested: .requested
        }
    }

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemGroupedBackground
        navigationItem.largeTitleDisplayMode = .never
        configureCollectionView()
        viewModel.onChange = { [weak self] in self?.render() }
        viewModel.onActionFailed = { [weak self] message in
            guard let self else { return }
            Feedback.failure(message, from: self)
        }
        // Back from iOS Settings, where access may have changed.
        NotificationCenter.default.addObserver(
            self, selector: #selector(appDidBecomeActive),
            name: UIApplication.didBecomeActiveNotification, object: nil
        )
        render()
        viewModel.start()
    }

    @objc private func appDidBecomeActive() {
        viewModel.accessMayHaveChanged()
    }

    private func configureCollectionView() {
        var config = UICollectionLayoutListConfiguration(appearance: .insetGrouped)
        config.headerMode = .supplementary
        config.footerMode = .supplementary
        collectionView = UICollectionView(
            frame: view.bounds,
            collectionViewLayout: UICollectionViewCompositionalLayout.list(using: config)
        )
        collectionView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        collectionView.prefersSoftTopEdge()
        collectionView.delegate = self
        view.addSubview(collectionView)

        let rowRegistration = UICollectionView.CellRegistration<RelationshipListCell, ProfileID> { [weak self] cell, _, id in
            guard let self, let row = rowsByID[id] else { return }
            cell.configure(with: ProfileRelationshipsViewModel.Row(
                id: row.id,
                displayName: row.displayName,
                handle: Self.subtitle(for: row),
                monogram: MonogramAvatarView.monogram(name: row.displayName, handle: row.handle),
                avatarURL: row.avatarURL,
                isVerified: false,
                action: Self.action(for: row),
                isViewer: false
            ), imagePipeline: imagePipeline)
            cell.loadAvatar(row.avatarURL)
            cell.onAction = { [weak self] in self?.viewModel.toggleFollow(id) }
        }
        dataSource = UICollectionViewDiffableDataSource<Int, ProfileID>(collectionView: collectionView) { collectionView, indexPath, id in
            collectionView.dequeueConfiguredReusableCell(using: rowRegistration, for: indexPath, item: id)
        }
        let header = UICollectionView.SupplementaryRegistration<UICollectionViewListCell>(
            elementKind: UICollectionView.elementKindSectionHeader
        ) { view, _, _ in
            var content = UIListContentConfiguration.header()
            content.text = Self.header
            view.contentConfiguration = content
        }
        let footer = UICollectionView.SupplementaryRegistration<UICollectionViewListCell>(
            elementKind: UICollectionView.elementKindSectionFooter
        ) { [weak self] view, _, _ in
            var content = UIListContentConfiguration.footer()
            content.text = self?.isLimited == true ? Self.limitedNote : nil
            view.contentConfiguration = content
        }
        dataSource.supplementaryViewProvider = { collectionView, kind, indexPath in
            kind == UICollectionView.elementKindSectionHeader
                ? collectionView.dequeueConfiguredReusableSupplementary(using: header, for: indexPath)
                : collectionView.dequeueConfiguredReusableSupplementary(using: footer, for: indexPath)
        }
    }

    // MARK: - Rendering

    private func render() {
        var snapshot = NSDiffableDataSourceSnapshot<Int, ProfileID>()
        if case .loaded(let rows, let limited) = viewModel.phase, !rows.isEmpty {
            isLimited = limited
            rowsByID = Dictionary(rows.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            snapshot.appendSections([0])
            snapshot.appendItems(rows.map(\.id))
            // A follow changes a row, not its identity: redraw them all.
            snapshot.reconfigureItems(rows.map(\.id))
        } else {
            rowsByID = [:]
        }
        dataSource.apply(snapshot, animatingDifferences: false)
        setNeedsUpdateContentUnavailableConfiguration()
    }

    override func updateContentUnavailableConfiguration(using state: UIContentUnavailableConfigurationState) {
        var configuration: UIContentUnavailableConfiguration?
        switch viewModel.phase {
        case .idle:
            configuration = nil
        case .loading:
            var loading = UIContentUnavailableConfiguration.loading()
            loading.text = "Checking your contacts…"
            configuration = loading
        case .needsPermission:
            configuration = Self.state(
                symbol: "person.crop.circle.badge.plus", title: Self.prePromptTitle, message: Self.prePromptMessage,
                button: "Continue", prominent: true
            ) { [weak self] in self?.viewModel.allowAccess() }
        case .denied:
            configuration = Self.state(
                symbol: "person.crop.circle.badge.xmark", title: Self.deniedTitle, message: Self.deniedMessage,
                button: "Open Settings"
            ) { Self.openSettings() }
        case .loaded(let rows, let limited) where rows.isEmpty:
            configuration = Self.state(
                symbol: "person.2", title: Self.emptyTitle,
                message: limited ? "\(Self.emptyMessage) \(Self.limitedNote)" : Self.emptyMessage,
                button: limited ? "Open Settings" : nil
            ) { Self.openSettings() }
        case .loaded:
            configuration = nil
        case .failed(let failure):
            configuration = Self.state(
                symbol: failure == .network(.offline) ? "wifi.slash" : "exclamationmark.triangle",
                title: failure == .dailyLimit ? "Try Again Tomorrow" : "Couldn't Check Your Contacts",
                message: Self.failureMessage(failure),
                button: failure == .dailyLimit ? nil : "Try Again"
            ) { [weak self] in self?.viewModel.retry() }
        }
        contentUnavailableConfiguration = configuration
    }

    private static func state(
        symbol: String, title: String, message: String, button: String?, prominent: Bool = false,
        action: @escaping @MainActor () -> Void
    ) -> UIContentUnavailableConfiguration {
        var configuration = UIContentUnavailableConfiguration.empty()
        configuration.image = UIImage(systemName: symbol)
        configuration.text = title
        configuration.secondaryText = message
        if let button {
            var style = prominent ? UIButton.Configuration.filled() : UIButton.Configuration.borderless()
            style.title = button
            configuration.button = style
            configuration.buttonProperties.primaryAction = UIAction { _ in action() }
        }
        return configuration
    }

    private static func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }
}

extension ContactFriendsViewController: UICollectionViewDelegate {
    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        guard let id = dataSource.itemIdentifier(for: indexPath) else { return }
        viewModel.rowTapped(id)
    }
}
