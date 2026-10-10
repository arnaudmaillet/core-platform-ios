import DesignSystem
import MediaCore
import UIKit

/// Settings → Privacy → Follow Requests (#396): who asked to follow the
/// active profile, newest first. Confirm makes them a follower; Delete drops
/// the request without telling them. From a tap (a sheet with both) or a
/// swipe (Confirm leading, Delete trailing).
final class FollowRequestsViewController: UIViewController {
    private enum Item: Hashable {
        case request(FollowRequest)
        case loading
        case failed
        case empty
    }

    private let viewModel: FollowRequestsViewModel
    private let imagePipeline: ImagePipeline?
    private var collectionView: UICollectionView!
    private var dataSource: UICollectionViewDiffableDataSource<Int, Item>!
    private let avatarLoads = RowAvatarLoads()

    init(viewModel: FollowRequestsViewModel, imagePipeline: ImagePipeline?) {
        self.viewModel = viewModel
        self.imagePipeline = imagePipeline
        super.init(nibName: nil, bundle: nil)
        title = "Follow Requests"
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

    static let footer = "Tap a request to confirm or delete it. Confirming lets them see this profile's posts and lists. If you delete it, they aren't told."

    private func configureCollectionView() {
        var config = UICollectionLayoutListConfiguration(appearance: .insetGrouped)
        config.footerMode = .supplementary
        config.leadingSwipeActionsConfigurationProvider = { [weak self] indexPath in
            guard let self, case .request(let request) = dataSource.itemIdentifier(for: indexPath) else { return nil }
            let action = UIContextualAction(style: .normal, title: "Confirm") { [weak self] _, _, done in
                self?.answer(request, confirm: true)
                done(true)
            }
            action.backgroundColor = .systemBlue
            return UISwipeActionsConfiguration(actions: [action])
        }
        config.trailingSwipeActionsConfigurationProvider = { [weak self] indexPath in
            guard let self, case .request(let request) = dataSource.itemIdentifier(for: indexPath) else { return nil }
            let action = UIContextualAction(style: .destructive, title: "Delete") { [weak self] _, _, done in
                self?.answer(request, confirm: false)
                done(true)
            }
            return UISwipeActionsConfiguration(actions: [action])
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
        let personRegistration = UICollectionView.CellRegistration<PersonListCell, FollowRequest> { [weak self] cell, _, request in
            cell.configure(with: PersonRowContent(
                displayName: request.displayName.isEmpty ? request.handle : request.displayName,
                handle: "@\(request.handle)",
                monogram: FollowRequestsViewModel.monogram(for: request)
            ))
            cell.accessibilityHint = "Confirm or delete this follow request."
            cell.setAvatarImage(nil)
            // One load per CELL, cancelled when the cell is configured again:
            // an unkept task painted the previous person's face on a
            // recycled row (#780).
            self?.avatarLoads.load(request.avatarURL, using: self?.imagePipeline, for: cell) { [weak cell] image in
                cell?.setAvatarImage(image)
            }
        }
        let messageRegistration = UICollectionView.CellRegistration<UICollectionViewListCell, Item> { cell, _, item in
            var content = UIListContentConfiguration.cell()
            content.textProperties.color = .secondaryLabel
            switch item {
            case .loading: content.text = "Loading…"
            case .failed: content.text = "Couldn't load follow requests. Tap to try again."
            case .empty: content.text = "No follow requests."
            case .request: break
            }
            cell.contentConfiguration = content
        }
        dataSource = UICollectionViewDiffableDataSource<Int, Item>(collectionView: collectionView) { collectionView, indexPath, item in
            if case .request(let request) = item {
                return collectionView.dequeueConfiguredReusableCell(using: personRegistration, for: indexPath, item: request)
            }
            return collectionView.dequeueConfiguredReusableCell(using: messageRegistration, for: indexPath, item: item)
        }
        let footer = UICollectionView.SupplementaryRegistration<UICollectionViewListCell>(
            elementKind: UICollectionView.elementKindSectionFooter
        ) { view, _, _ in
            var content = UIListContentConfiguration.footer()
            content.text = Self.footer
            view.contentConfiguration = content
        }
        dataSource.supplementaryViewProvider = { collectionView, _, indexPath in
            collectionView.dequeueConfiguredReusableSupplementary(using: footer, for: indexPath)
        }
    }

    private func applySnapshot() {
        var snapshot = NSDiffableDataSourceSnapshot<Int, Item>()
        snapshot.appendSections([0])
        switch viewModel.phase {
        case .loading: snapshot.appendItems([.loading])
        case .failed: snapshot.appendItems([.failed])
        case .loaded(let requests) where requests.isEmpty: snapshot.appendItems([.empty])
        case .loaded(let requests): snapshot.appendItems(requests.map(Item.request))
        }
        dataSource.apply(snapshot, animatingDifferences: view.window != nil)
    }

    private func presentChoices(for request: FollowRequest, from indexPath: IndexPath) {
        let sheet = UIAlertController(
            title: "@\(request.handle) wants to follow you",
            message: nil,
            preferredStyle: .actionSheet
        )
        sheet.addAction(UIAlertAction(title: "Confirm", style: .default) { [weak self] _ in
            self?.answer(request, confirm: true)
        })
        sheet.addAction(UIAlertAction(title: "Delete Request", style: .destructive) { [weak self] _ in
            self?.answer(request, confirm: false)
        })
        sheet.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        if let popover = sheet.popoverPresentationController, let cell = collectionView.cellForItem(at: indexPath) {
            popover.sourceView = cell
            popover.sourceRect = cell.bounds
        }
        present(sheet, animated: true)
    }

    private func answer(_ request: FollowRequest, confirm: Bool) {
        Task { [weak self] in
            guard let self else { return }
            do {
                if confirm {
                    try await viewModel.confirm(request)
                } else {
                    try await viewModel.delete(request)
                }
                HapticNotification().notificationOccurred(.success)
            } catch {
                let verb = confirm ? "confirm" : "delete"
                let alert = UIAlertController(title: nil, message: "Couldn't \(verb) @\(request.handle)'s request. Try again.", preferredStyle: .alert)
                alert.addAction(UIAlertAction(title: "OK", style: .default))
                present(alert, animated: true)
            }
        }
    }
}

extension FollowRequestsViewController: UICollectionViewDelegate {
    func collectionView(_ collectionView: UICollectionView, shouldHighlightItemAt indexPath: IndexPath) -> Bool {
        switch dataSource.itemIdentifier(for: indexPath) {
        case .request, .failed: true
        default: false
        }
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        switch dataSource.itemIdentifier(for: indexPath) {
        case .request(let request): presentChoices(for: request, from: indexPath)
        case .failed: Task { await viewModel.load() }
        default: break
        }
    }
}
