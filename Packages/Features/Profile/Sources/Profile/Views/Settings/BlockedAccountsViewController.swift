import DesignSystem
import MediaCore
import UIKit

/// Settings → Safety and Interactions → Blocked Accounts (#389, App Review
/// 1.2): who the active profile has blocked, newest first, and Unblock —
/// from a tap (with confirmation) or a swipe.
final class BlockedAccountsViewController: UIViewController {
    private enum Item: Hashable {
        case profile(BlockedProfile)
        case loading
        case failed
        case empty
    }

    private let viewModel: BlockedAccountsViewModel
    private let imagePipeline: ImagePipeline?
    private var collectionView: UICollectionView!
    private var dataSource: UICollectionViewDiffableDataSource<Int, Item>!

    init(viewModel: BlockedAccountsViewModel, imagePipeline: ImagePipeline?) {
        self.viewModel = viewModel
        self.imagePipeline = imagePipeline
        super.init(nibName: nil, bundle: nil)
        title = "Blocked Accounts"
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

    private func configureCollectionView() {
        var config = UICollectionLayoutListConfiguration(appearance: .insetGrouped)
        config.footerMode = .supplementary
        config.trailingSwipeActionsConfigurationProvider = { [weak self] indexPath in
            guard let self, case .profile(let profile) = dataSource.itemIdentifier(for: indexPath) else { return nil }
            let action = UIContextualAction(style: .normal, title: "Unblock") { [weak self] _, _, done in
                self?.unblock(profile)
                done(true)
            }
            action.backgroundColor = .systemBlue
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
        let personRegistration = UICollectionView.CellRegistration<PersonListCell, BlockedProfile> { [weak self] cell, _, profile in
            cell.configure(with: PersonRowContent(
                displayName: profile.displayName.isEmpty ? profile.handle : profile.displayName,
                handle: "@\(profile.handle)",
                monogram: BlockedAccountsViewModel.monogram(for: profile)
            ))
            cell.setAvatarImage(nil)
            guard let url = profile.avatarURL, let pipeline = self?.imagePipeline else { return }
            Task { [weak cell] in
                let image = try? await pipeline.image(for: url)
                cell?.setAvatarImage(image)
            }
        }
        let messageRegistration = UICollectionView.CellRegistration<UICollectionViewListCell, Item> { cell, _, item in
            var content = UIListContentConfiguration.cell()
            content.textProperties.color = .secondaryLabel
            switch item {
            case .loading: content.text = "Loading…"
            case .failed: content.text = "Couldn't load blocked accounts. Tap to try again."
            case .empty: content.text = "You haven't blocked anyone."
            case .profile: break
            }
            cell.contentConfiguration = content
        }
        dataSource = UICollectionViewDiffableDataSource<Int, Item>(collectionView: collectionView) { collectionView, indexPath, item in
            if case .profile(let profile) = item {
                return collectionView.dequeueConfiguredReusableCell(using: personRegistration, for: indexPath, item: profile)
            }
            return collectionView.dequeueConfiguredReusableCell(using: messageRegistration, for: indexPath, item: item)
        }
        let footer = UICollectionView.SupplementaryRegistration<UICollectionViewListCell>(
            elementKind: UICollectionView.elementKindSectionFooter
        ) { view, _, _ in
            var content = UIListContentConfiguration.footer()
            content.text = "Blocked accounts can't find this profile, see its posts or message it. They aren't told you blocked them."
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
        case .loaded(let profiles) where profiles.isEmpty: snapshot.appendItems([.empty])
        case .loaded(let profiles): snapshot.appendItems(profiles.map(Item.profile))
        }
        dataSource.apply(snapshot, animatingDifferences: view.window != nil)
    }

    private func confirmUnblock(_ profile: BlockedProfile) {
        let sheet = UIAlertController(
            title: "Unblock @\(profile.handle)?",
            message: "They'll be able to find this profile, see its posts and message it again.",
            preferredStyle: .actionSheet
        )
        sheet.addAction(UIAlertAction(title: "Unblock", style: .default) { [weak self] _ in
            self?.unblock(profile)
        })
        sheet.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        if let popover = sheet.popoverPresentationController {
            popover.sourceView = view
            popover.sourceRect = CGRect(x: view.bounds.midX, y: view.bounds.maxY - 60, width: 0, height: 0)
            popover.permittedArrowDirections = []
        }
        present(sheet, animated: true)
    }

    private func unblock(_ profile: BlockedProfile) {
        Task { [weak self] in
            guard let self else { return }
            do {
                try await viewModel.unblock(profile)
            } catch {
                let alert = UIAlertController(title: nil, message: "Couldn't unblock @\(profile.handle). Try again.", preferredStyle: .alert)
                alert.addAction(UIAlertAction(title: "OK", style: .default))
                present(alert, animated: true)
            }
        }
    }
}

extension BlockedAccountsViewController: UICollectionViewDelegate {
    func collectionView(_ collectionView: UICollectionView, shouldHighlightItemAt indexPath: IndexPath) -> Bool {
        switch dataSource.itemIdentifier(for: indexPath) {
        case .profile, .failed: true
        default: false
        }
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        switch dataSource.itemIdentifier(for: indexPath) {
        case .profile(let profile): confirmUnblock(profile)
        case .failed: Task { await viewModel.load() }
        default: break
        }
    }
}
