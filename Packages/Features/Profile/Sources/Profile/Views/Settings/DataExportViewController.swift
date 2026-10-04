import DesignSystem
import UIKit

/// Settings → Account → Download Your Data (#387, GDPR Art. 15 and 20).
///
/// `account.v1` records the request and when it completed, and carries no
/// download link, so the file reaches the user outside the app — by email.
/// The screen says where it is going rather than promising an in-app button.
final class DataExportViewController: UIViewController {
    private enum Item: Hashable {
        case status
        case request(title: String)
    }

    private let viewModel: DataExportViewModel
    /// Where the file is sent, when the account's email is known.
    private let email: String?
    private var collectionView: UICollectionView!
    private var dataSource: UICollectionViewDiffableDataSource<Int, Item>!

    init(viewModel: DataExportViewModel, email: String?) {
        self.viewModel = viewModel
        self.email = email
        super.init(nibName: nil, bundle: nil)
        title = "Download Your Data"
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

    /// The status line, pure so tests pin the wording.
    static func statusText(for phase: DataExportViewModel.Phase, email: String?) -> String {
        let destination = email.map { "to \($0)" } ?? "to your email address"
        switch phase {
        case .loading:
            return "Checking…"
        case .available:
            return "Get a copy of the information linked to your account, as machine-readable files (JSON)."
        case .preparing(let requestedOn):
            return "Requested on \(dateFormatter.string(from: requestedOn)). Preparing the file can take up to 30 days; it will be sent \(destination)."
        case .ready(let completedOn):
            return "Your file was prepared on \(dateFormatter.string(from: completedOn)) and sent \(destination)."
        }
    }

    private func configureCollectionView() {
        var config = UICollectionLayoutListConfiguration(appearance: .insetGrouped)
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
        let registration = UICollectionView.CellRegistration<UICollectionViewListCell, Item> { [weak self] cell, _, item in
            guard let self else { return }
            var content = UIListContentConfiguration.cell()
            switch item {
            case .status:
                content.text = Self.statusText(for: viewModel.phase, email: email)
                content.textProperties.color = .secondaryLabel
                content.image = UIImage(systemName: "doc.zipper")
                content.imageProperties.tintColor = .label
            case .request(let title):
                content.text = title
                content.textProperties.color = .tintColor
            }
            cell.contentConfiguration = content
        }
        dataSource = UICollectionViewDiffableDataSource<Int, Item>(collectionView: collectionView) { collectionView, indexPath, item in
            collectionView.dequeueConfiguredReusableCell(using: registration, for: indexPath, item: item)
        }
        let footer = UICollectionView.SupplementaryRegistration<UICollectionViewListCell>(
            elementKind: UICollectionView.elementKindSectionFooter
        ) { view, _, indexPath in
            var content = UIListContentConfiguration.footer()
            content.text = indexPath.section == 1 ? "Your data stays on your account; downloading a copy doesn't delete anything." : nil
            view.contentConfiguration = content
        }
        dataSource.supplementaryViewProvider = { collectionView, _, indexPath in
            collectionView.dequeueConfiguredReusableSupplementary(using: footer, for: indexPath)
        }
    }

    private func applySnapshot() {
        var snapshot = NSDiffableDataSourceSnapshot<Int, Item>()
        snapshot.appendSections([0])
        snapshot.appendItems([.status], toSection: 0)
        switch viewModel.phase {
        case .available:
            snapshot.appendSections([1])
            snapshot.appendItems([.request(title: "Request Download")], toSection: 1)
        case .ready:
            snapshot.appendSections([1])
            snapshot.appendItems([.request(title: "Request a New Copy")], toSection: 1)
        case .loading, .preparing:
            break
        }
        snapshot.reconfigureItems([.status])
        dataSource.apply(snapshot, animatingDifferences: false)
    }

    private func requestExport() {
        Task { [weak self] in
            guard let self else { return }
            do {
                try await viewModel.requestExport()
            } catch {
                let alert = UIAlertController(title: nil, message: "Couldn't request your data. Try again.", preferredStyle: .alert)
                alert.addAction(UIAlertAction(title: "OK", style: .default))
                present(alert, animated: true)
            }
        }
    }
}

extension DataExportViewController: UICollectionViewDelegate {
    func collectionView(_ collectionView: UICollectionView, shouldHighlightItemAt indexPath: IndexPath) -> Bool {
        if case .request = dataSource.itemIdentifier(for: indexPath) { return true }
        return false
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        if case .request = dataSource.itemIdentifier(for: indexPath) {
            requestExport()
        }
    }
}
