import DesignSystem
import UIKit

/// Settings → Account → Delete Account (#386, App Review 5.1.1(v), GDPR
/// Art. 17): what goes, when it becomes permanent, one button, one final
/// confirmation, then sign-out.
///
/// No password step. There is no verify-credentials RPC, and re-running
/// `auth.v1.Login` would open a new session the client cannot name (it does
/// not know the IdP username). The guard is two explicit confirmations and a
/// 30-day window instead; a step-up RPC can slot in before the request later.
///
/// No cancel button either: `account.v1` has no RPC to withdraw a request, so
/// the screen says to contact support rather than offering an undo it cannot
/// perform.
final class DeleteAccountViewController: UIViewController {
    private enum Section: Hashable {
        case consequences, beforeYouGo, action
    }

    private enum Item: Hashable {
        case consequence(String)
        case downloadData
        case loading
        case delete
        case requested
        case cancelRequest
    }

    private static let consequences = [
        "Every profile on this account",
        "Posts, comments and messages",
        "Followers, following and saved posts",
        "Points and gems in your wallet"
    ]

    private let viewModel: DeleteAccountViewModel
    private let onAccountDeleted: () -> Void
    /// "Download your data first" — offered before the irreversible step.
    private let makeDataExport: () -> UIViewController?
    private let stepUp: (any CredentialStepUp)?
    private let canceller: (any AccountDeletionCancelling)?
    private var collectionView: UICollectionView!
    private var dataSource: UICollectionViewDiffableDataSource<Section, Item>!

    init(
        viewModel: DeleteAccountViewModel,
        onAccountDeleted: @escaping () -> Void,
        makeDataExport: @escaping () -> UIViewController? = { nil },
        stepUp: (any CredentialStepUp)? = nil,
        canceller: (any AccountDeletionCancelling)? = nil
    ) {
        self.canceller = canceller
        self.viewModel = viewModel
        self.onAccountDeleted = onAccountDeleted
        self.makeDataExport = makeDataExport
        self.stepUp = stepUp
        super.init(nibName: nil, bundle: nil)
        title = "Delete Account"
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

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .long
        formatter.timeStyle = .none
        return formatter
    }()

    static func footer(for phase: DeleteAccountViewModel.Phase) -> String? {
        switch phase {
        case .loading:
            nil
        case .ready(let permanentOn):
            "Deletion becomes permanent on \(dateFormatter.string(from: permanentOn)), "
                + "\(AccountDeletionPolicy.gracePeriodDays) days after you ask. "
                + "Until then your profiles are hidden, and logging back in cancels it."
        case .requested(let on, let permanentOn):
            "You asked to delete this account on \(dateFormatter.string(from: on)). "
                + "It becomes permanent on \(dateFormatter.string(from: permanentOn)). "
                + "Until then you can cancel it here, or by logging back in."
        }
    }

    // MARK: - Setup

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
    }

    private func configureDataSource() {
        let registration = UICollectionView.CellRegistration<UICollectionViewListCell, Item> { cell, _, item in
            var content = UIListContentConfiguration.cell()
            cell.accessories = []
            switch item {
            case .consequence(let text):
                content.text = text
                content.image = UIImage(systemName: "minus.circle")
                content.imageProperties.tintColor = .secondaryLabel
            case .downloadData:
                content.text = "Download Your Data"
                content.image = UIImage(systemName: "arrow.down.doc")
                content.imageProperties.tintColor = .label
                cell.accessories = [.disclosureIndicator()]
            case .loading:
                content.text = "Checking your account…"
                content.textProperties.color = .secondaryLabel
            case .delete:
                content.text = "Delete Account"
                content.textProperties.color = .systemRed
            case .requested:
                content.text = "Deletion Requested"
                content.textProperties.color = .secondaryLabel
            case .cancelRequest:
                content.text = "Cancel Deletion Request"
                content.textProperties.color = .tintColor
            }
            cell.contentConfiguration = content
        }
        dataSource = UICollectionViewDiffableDataSource<Section, Item>(collectionView: collectionView) { collectionView, indexPath, item in
            collectionView.dequeueConfiguredReusableCell(using: registration, for: indexPath, item: item)
        }
        let header = UICollectionView.SupplementaryRegistration<UICollectionViewListCell>(
            elementKind: UICollectionView.elementKindSectionHeader
        ) { [weak self] view, _, indexPath in
            var content = UIListContentConfiguration.header()
            switch self?.dataSource.sectionIdentifier(for: indexPath.section) {
            case .consequences: content.text = "What Gets Deleted"
            case .beforeYouGo: content.text = "Before You Go"
            default: content.text = nil
            }
            view.contentConfiguration = content
        }
        let footer = UICollectionView.SupplementaryRegistration<UICollectionViewListCell>(
            elementKind: UICollectionView.elementKindSectionFooter
        ) { [weak self] view, _, indexPath in
            guard let self else { return }
            var content = UIListContentConfiguration.footer()
            content.text = dataSource.sectionIdentifier(for: indexPath.section) == .action ? Self.footer(for: viewModel.phase) : nil
            view.contentConfiguration = content
        }
        dataSource.supplementaryViewProvider = { collectionView, kind, indexPath in
            kind == UICollectionView.elementKindSectionHeader
                ? collectionView.dequeueConfiguredReusableSupplementary(using: header, for: indexPath)
                : collectionView.dequeueConfiguredReusableSupplementary(using: footer, for: indexPath)
        }
    }

    private func applySnapshot() {
        var snapshot = NSDiffableDataSourceSnapshot<Section, Item>()
        snapshot.appendSections([.consequences])
        snapshot.appendItems(Self.consequences.map(Item.consequence), toSection: .consequences)
        if case .ready = viewModel.phase, hasDataExport {
            snapshot.appendSections([.beforeYouGo])
            snapshot.appendItems([.downloadData], toSection: .beforeYouGo)
        }
        snapshot.appendSections([.action])
        switch viewModel.phase {
        case .loading: snapshot.appendItems([.loading], toSection: .action)
        case .ready: snapshot.appendItems([.delete], toSection: .action)
        case .requested:
            snapshot.appendItems(canceller == nil ? [.requested] : [.requested, .cancelRequest], toSection: .action)
        }
        // The footer carries the dates; reload it with the row.
        snapshot.reloadSections([.action])
        dataSource.apply(snapshot, animatingDifferences: false)
    }

    private lazy var hasDataExport = makeDataExport() != nil

    // MARK: - Actions

    private func confirmDeletion() {
        guard case .ready(let permanentOn) = viewModel.phase else { return }
        let alert = UIAlertController(
            title: "Delete your account?",
            message: "Every profile and everything on them will be permanently deleted on "
                + "\(Self.dateFormatter.string(from: permanentOn)). You'll be logged out now; "
                + "logging back in before then cancels it.",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Delete", style: .destructive) { [weak self] _ in
            self?.verifyThenRequestDeletion()
        })
        present(alert, animated: true)
    }

    /// The server gates deletion behind a fresh step-up (#648): the password
    /// first, then the request on the token it mints.
    private func verifyThenRequestDeletion() {
        guard let stepUp else { requestDeletion(); return }
        StepUpPrompt.present(
            on: self,
            message: "To delete your account, confirm it's you.",
            actionTitle: "Delete",
            stepUp: stepUp,
            onVerified: { [weak self] in self?.requestDeletion() },
            onFailure: { [weak self] _ in
                let failed = UIAlertController(
                    title: nil, message: "Couldn't confirm your password. Check your connection and try again.", preferredStyle: .alert
                )
                failed.addAction(UIAlertAction(title: "OK", style: .default))
                self?.present(failed, animated: true)
            }
        )
    }

    private func requestDeletion() {
        Task { [weak self] in
            guard let self else { return }
            do {
                let permanentOn = try await viewModel.requestDeletion()
                // So the next login on this iPhone can say the deletion was
                // cancelled, not just that the account is active again.
                PendingDeletionNotice.recordRequest()
                let done = UIAlertController(
                    title: "Deletion requested",
                    message: "Your account will be permanently deleted on \(Self.dateFormatter.string(from: permanentOn)). "
                        + "Log back in before then to cancel it.",
                    preferredStyle: .alert
                )
                done.addAction(UIAlertAction(title: "OK", style: .default) { [weak self] _ in
                    self?.onAccountDeleted()
                })
                present(done, animated: true)
            } catch AccountError.stepUpRequired where stepUp != nil {
                // The proof expired between the two calls: ask again.
                verifyThenRequestDeletion()
            } catch {
                let failed = UIAlertController(title: nil, message: "Couldn't request deletion. Try again.", preferredStyle: .alert)
                failed.addAction(UIAlertAction(title: "OK", style: .default))
                present(failed, animated: true)
            }
        }
    }
}

extension DeleteAccountViewController {
    /// Withdraws the pending erasure (#402); the screen goes back to its
    /// ready state.
    fileprivate func cancelRequest() {
        guard let canceller else { return }
        Task { [weak self] in
            guard let self else { return }
            do {
                try await canceller.cancelDeletion()
                PendingDeletionNotice.clear()
                await viewModel.load()
                presentMessage("Deletion cancelled. Your account stays.")
            } catch DeletionCancelError.nothingPending {
                await viewModel.load()
                presentMessage("There's no deletion to cancel.")
            } catch DeletionCancelError.tooLate {
                presentMessage("It's too late to cancel: the deletion is being completed.")
            } catch {
                presentMessage("Couldn't cancel the deletion. Try again.")
            }
        }
    }

    private func presentMessage(_ message: String) {
        let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }
}

extension DeleteAccountViewController: UICollectionViewDelegate {
    func collectionView(_ collectionView: UICollectionView, shouldHighlightItemAt indexPath: IndexPath) -> Bool {
        let item = dataSource.itemIdentifier(for: indexPath)
        return item == .delete || item == .downloadData || item == .cancelRequest
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        switch dataSource.itemIdentifier(for: indexPath) {
        case .delete:
            confirmDeletion()
        case .cancelRequest:
            cancelRequest()
        case .downloadData:
            if let export = makeDataExport() {
                navigationController?.pushViewController(export, animated: true)
            }
        default:
            break
        }
    }
}
