import CoreNetworking
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
    enum Section: Hashable {
        case consequences, beforeYouGo, action
    }

    enum Item: Hashable {
        case consequence(String)
        case downloadData
        /// A row-shaped bone while the account is checked (charter P8).
        case skeleton(Int)
        case delete
        case requested
        case cancelRequest
        /// The account couldn't be checked: read it again.
        case retry
    }

    /// What gets deleted, as concrete as the account allows (#402): the
    /// profiles by handle and the wallet's balance when they could be read,
    /// the general wording otherwise.
    static func consequences(for checklist: DeletionChecklist?) -> [String] {
        [
            profilesLine(checklist?.profileHandles),
            "Posts, comments and messages",
            "Followers, following and saved posts",
            walletLine(points: checklist?.points, gems: checklist?.gems),
        ]
    }

    static func profilesLine(_ handles: [String]?) -> String {
        guard let handles, !handles.isEmpty else { return "Every profile on this account" }
        let named = handles.map { "@" + $0 }
        if named.count == 1 { return "Your profile \(named[0])" }
        let shown = named.prefix(3).joined(separator: ", ")
        let more = named.count > 3 ? " and \(named.count - 3) more" : ""
        return "All \(named.count) profiles on this account: \(shown)\(more)"
    }

    static func walletLine(points: Int?, gems: Int?) -> String {
        let parts = [
            points.flatMap { $0 > 0 ? count($0, "point") : nil },
            gems.flatMap { $0 > 0 ? count($0, "gem") : nil },
        ].compactMap { $0 }
        guard !parts.isEmpty else { return "Points and gems in your wallet" }
        return "Your " + parts.joined(separator: " and ") + ". They can't be refunded or moved to another account"
    }

    private static func count(_ value: Int, _ noun: String) -> String {
        "\(value.formatted()) \(noun)\(value == 1 ? "" : "s")"
    }

    private let viewModel: DeleteAccountViewModel
    private let onAccountDeleted: () -> Void
    /// "Download your data first" — offered before the irreversible step.
    private let makeDataExport: () -> UIViewController?
    private let stepUp: (any CredentialStepUp)?
    private let canceller: (any AccountDeletionCancelling)?
    private var collectionView: UICollectionView!
    private var dataSource: UICollectionViewDiffableDataSource<Section, Item>!
    /// Whether the list last drew bones: leaving them cross-fades (P10).
    private var isShowingSkeleton = false

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

    /// `failure` words the failed footer: "You’re offline…" when that is why
    /// the record couldn't be reached (#794).
    static func footer(for phase: DeleteAccountViewModel.Phase, failure: NetworkFailure? = nil) -> String? {
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
        case .failed:
            FailureCopy.message(
                for: failure,
                fallback: "Couldn't check whether a deletion is already pending. Check your connection and try again."
            )
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
            case .skeleton:
                // Drawn by `SettingsSkeletonRowCell`.
                break
            case .delete:
                content.text = "Delete Account"
                content.textProperties.color = .systemRed
            case .requested:
                content.text = "Deletion Requested"
                content.textProperties.color = .secondaryLabel
            case .cancelRequest:
                content.text = "Cancel Deletion Request"
                content.textProperties.color = .tintColor
            case .retry:
                content.text = "Try Again"
                content.textProperties.color = .tintColor
            }
            cell.contentConfiguration = content
        }
        let skeletonRegistration = UICollectionView.CellRegistration<SettingsSkeletonRowCell, Int> { cell, _, index in
            cell.configure(redacting: Self.placeholder(index))
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
            content.text = dataSource.sectionIdentifier(for: indexPath.section) == .action ? Self.footer(for: viewModel.phase, failure: viewModel.failure) : nil
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
        let layout = Self.layout(
            phase: viewModel.phase, checklist: viewModel.checklist,
            offersDataExport: hasDataExport, canCancel: canceller != nil
        )
        for (section, items) in layout {
            snapshot.appendSections([section])
            snapshot.appendItems(items, toSection: section)
        }
        // The footer carries the dates; reload it with the row.
        snapshot.reloadSections([.action])

        let wasShowingSkeleton = isShowingSkeleton
        isShowingSkeleton = viewModel.phase == .loading
        if wasShowingSkeleton, !isShowingSkeleton {
            collectionView.crossfadeSkeleton { [dataSource, snapshot] in
                dataSource?.apply(snapshot, animatingDifferences: false)
            }
        } else {
            dataSource.apply(snapshot, animatingDifferences: false)
        }
    }

    /// The screen's sections and rows. The sections are the same before and
    /// after the account is read — bones stand in for the consequences and
    /// the button while it is — so nothing is inserted above the button when
    /// the read lands. Download Your Data is offered whatever the phase: it
    /// doesn't depend on the read, and a pending deletion is exactly when
    /// someone still wants their copy.
    static func layout(
        phase: DeleteAccountViewModel.Phase,
        checklist: DeletionChecklist?,
        offersDataExport: Bool,
        canCancel: Bool
    ) -> [(Section, [Item])] {
        var layout: [(Section, [Item])] = []
        if phase == .loading {
            layout.append((.consequences, consequences(for: nil).indices.map(Item.skeleton)))
        } else {
            layout.append((.consequences, consequences(for: checklist).map(Item.consequence)))
        }
        if offersDataExport {
            layout.append((.beforeYouGo, [.downloadData]))
        }
        switch phase {
        case .loading:
            layout.append((.action, [.skeleton(consequences(for: nil).count)]))
        case .ready:
            layout.append((.action, [.delete]))
        case .requested:
            layout.append((.action, canCancel ? [.requested, .cancelRequest] : [.requested]))
        case .failed:
            layout.append((.action, [.retry]))
        }
        return layout
    }

    /// The row a bone stands for, with sample words: a consequence line, or
    /// (past the last of them) the action row. Only the bones' widths come
    /// from them.
    private static func placeholder(_ index: Int) -> UIListContentConfiguration {
        let lines = consequences(for: nil)
        var content = UIListContentConfiguration.cell()
        if lines.indices.contains(index) {
            content.text = lines[index]
            content.image = UIImage(systemName: "minus.circle")
        } else {
            content.text = "Delete Account"
        }
        return content
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
        return item == .delete || item == .downloadData || item == .cancelRequest || item == .retry
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        switch dataSource.itemIdentifier(for: indexPath) {
        case .delete:
            confirmDeletion()
        case .cancelRequest:
            cancelRequest()
        case .retry:
            Task { await viewModel.load() }
        case .downloadData:
            if let export = makeDataExport() {
                navigationController?.pushViewController(export, animated: true)
            }
        default:
            break
        }
    }
}
