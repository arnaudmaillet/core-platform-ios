import DesignSystem
import MediaCore
import UIKit

/// Settings → Safety and Interactions → Muted Accounts (#403): who the active
/// profile has muted and what of them, newest first, and Unmute — from a tap
/// (with confirmation) or a swipe. To change one scope, the profile's "..."
/// menu has the toggles.
final class MutedAccountsViewController: UIViewController {
    private enum Item: Hashable {
        case profile(MutedProfile)
        case loading
        case failed
        case empty
    }

    private let viewModel: MutedAccountsViewModel
    private let imagePipeline: ImagePipeline?
    private var collectionView: UICollectionView!
    private var dataSource: UICollectionViewDiffableDataSource<Int, Item>!

    init(viewModel: MutedAccountsViewModel, imagePipeline: ImagePipeline?) {
        self.viewModel = viewModel
        self.imagePipeline = imagePipeline
        super.init(nibName: nil, bundle: nil)
        title = "Muted Accounts"
        hidesBottomBarWhenPushed = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    static let footer = "Muted accounts aren't told. They can still see your profile and follow you. To mute only part of an account, use the ••• menu on its profile."

    override func viewDidLoad() {
        super.viewDidLoad()
        navigationItem.largeTitleDisplayMode = .never
        var config = UICollectionLayoutListConfiguration(appearance: .insetGrouped)
        config.footerMode = .supplementary
        config.trailingSwipeActionsConfigurationProvider = { [weak self] indexPath in
            guard let self, case .profile(let profile) = dataSource.itemIdentifier(for: indexPath) else { return nil }
            let action = UIContextualAction(style: .normal, title: "Unmute") { [weak self] _, _, done in
                self?.unmute(profile)
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
        configureDataSource()
        viewModel.onChange = { [weak self] in self?.applySnapshot() }
        applySnapshot()
        Task { await viewModel.load() }
    }

    private func configureDataSource() {
        let personRegistration = UICollectionView.CellRegistration<PersonListCell, MutedProfile> { [weak self] cell, _, profile in
            cell.configure(with: PersonRowContent(
                displayName: profile.displayName.isEmpty ? profile.handle : profile.displayName,
                handle: MutedAccountsViewModel.detail(for: profile),
                monogram: MutedAccountsViewModel.monogram(for: profile)
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
            case .failed: content.text = "Couldn't load muted accounts. Tap to try again."
            case .empty: content.text = "You haven't muted anyone."
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
        case .loaded(let profiles) where profiles.isEmpty: snapshot.appendItems([.empty])
        case .loaded(let profiles): snapshot.appendItems(profiles.map(Item.profile))
        }
        dataSource.apply(snapshot, animatingDifferences: view.window != nil)
    }

    private func confirmUnmute(_ profile: MutedProfile, from indexPath: IndexPath) {
        let sheet = UIAlertController(
            title: "Unmute @\(profile.handle)?",
            message: "You'll see their \(profile.scopes.summary.lowercased()) again.",
            preferredStyle: .actionSheet
        )
        sheet.addAction(UIAlertAction(title: "Unmute", style: .default) { [weak self] _ in
            self?.unmute(profile)
        })
        sheet.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        if let popover = sheet.popoverPresentationController, let cell = collectionView.cellForItem(at: indexPath) {
            popover.sourceView = cell
            popover.sourceRect = cell.bounds
        }
        present(sheet, animated: true)
    }

    private func unmute(_ profile: MutedProfile) {
        Task { [weak self] in
            guard let self else { return }
            do {
                try await viewModel.unmute(profile)
            } catch {
                let alert = UIAlertController(title: nil, message: "Couldn't unmute @\(profile.handle). Try again.", preferredStyle: .alert)
                alert.addAction(UIAlertAction(title: "OK", style: .default))
                present(alert, animated: true)
            }
        }
    }
}

extension MutedAccountsViewController: UICollectionViewDelegate {
    func collectionView(_ collectionView: UICollectionView, shouldHighlightItemAt indexPath: IndexPath) -> Bool {
        switch dataSource.itemIdentifier(for: indexPath) {
        case .profile, .failed: true
        default: false
        }
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        switch dataSource.itemIdentifier(for: indexPath) {
        case .profile(let profile): confirmUnmute(profile, from: indexPath)
        case .failed: Task { await viewModel.load() }
        default: break
        }
    }
}
