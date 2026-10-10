import CoreNetworking
import DesignSystem
import MediaCore
import UIKit

/// State for Settings → Safety → Restricted Accounts (#416).
@MainActor
final class RestrictedAccountsViewModel {
    enum Phase: Equatable {
        case loading
        case loaded([RestrictedProfile])
        case failed
    }

    private(set) var phase: Phase = .loading {
        didSet { onChange?() }
    }
    /// Why the last load failed, kept beside `.failed` so the failed row
    /// can say "You’re offline" when that is the cause (#794). Set before
    /// the phase, so the redraw `.failed` triggers already reads it.
    private(set) var failure: NetworkFailure?
    var onChange: (() -> Void)?

    private let restricting: any ProfileRestricting

    init(restricting: any ProfileRestricting) {
        self.restricting = restricting
    }

    func load() async {
        if case .failed = phase { phase = .loading }
        do {
            phase = .loaded(try await restricting.restrictedProfiles())
        } catch {
            failure = NetworkFailure.of(error)
            phase = .failed
        }
    }

    /// Unrestricts and drops the row once the server agrees.
    func unrestrict(_ profile: RestrictedProfile) async throws {
        try await restricting.setRestricted(false, for: profile.id)
        if case .loaded(let current) = phase {
            phase = .loaded(current.filter { $0.id != profile.id })
        }
    }
}

/// Settings → Safety and Interactions → Restricted Accounts (#416): who the
/// active profile has restricted, newest first, and Unrestrict — from a tap
/// (with confirmation) or a swipe.
final class RestrictedAccountsViewController: UIViewController {
    private enum Item: Hashable {
        case profile(RestrictedProfile)
        case loading
        case failed
        case empty
    }

    private let viewModel: RestrictedAccountsViewModel
    private let imagePipeline: ImagePipeline?
    private var collectionView: UICollectionView!
    private var dataSource: UICollectionViewDiffableDataSource<Int, Item>!
    private let avatarLoads = RowAvatarLoads()

    init(viewModel: RestrictedAccountsViewModel, imagePipeline: ImagePipeline?) {
        self.viewModel = viewModel
        self.imagePipeline = imagePipeline
        super.init(nibName: nil, bundle: nil)
        title = "Restricted Accounts"
        hidesBottomBarWhenPushed = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    static let footer = "A restricted account's comments on your posts are seen only by them and you. They aren't told, and they can still follow you."

    override func viewDidLoad() {
        super.viewDidLoad()
        navigationItem.largeTitleDisplayMode = .never
        var config = UICollectionLayoutListConfiguration(appearance: .insetGrouped)
        config.footerMode = .supplementary
        config.trailingSwipeActionsConfigurationProvider = { [weak self] indexPath in
            guard let self, case .profile(let profile) = dataSource.itemIdentifier(for: indexPath) else { return nil }
            let action = UIContextualAction(style: .normal, title: "Unrestrict") { [weak self] _, _, done in
                self?.unrestrict(profile)
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
        let personRegistration = UICollectionView.CellRegistration<PersonListCell, RestrictedProfile> { [weak self] cell, _, profile in
            cell.configure(with: PersonRowContent(
                displayName: profile.displayName.isEmpty ? profile.handle : profile.displayName,
                handle: "@\(profile.handle)",
                monogram: MonogramAvatarView.monogram(name: profile.displayName, handle: profile.handle)
            ))
            cell.setAvatarImage(nil)
            // One load per CELL, cancelled when the cell is configured again:
            // an unkept task painted the previous person's face on a
            // recycled row (#780).
            self?.avatarLoads.load(profile.avatarURL, using: self?.imagePipeline, for: cell) { [weak cell] image in
                cell?.setAvatarImage(image)
            }
        }
        let messageRegistration = UICollectionView.CellRegistration<UICollectionViewListCell, Item> { [weak self] cell, _, item in
            var content = UIListContentConfiguration.cell()
            content.textProperties.color = .secondaryLabel
            switch item {
            case .loading: content.text = "Loading…"
            case .failed:
                // "You’re offline…" when that is why (#794).
                content.text = FailureCopy.row(
                    for: self?.viewModel.failure, fallback: "Couldn't load restricted accounts. Tap to try again."
                )
            case .empty: content.text = "You haven't restricted anyone."
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

    private func confirmUnrestrict(_ profile: RestrictedProfile, from indexPath: IndexPath) {
        let sheet = UIAlertController(
            title: "Unrestrict @\(profile.handle)?",
            message: "Everyone will see their comments on your posts again.",
            preferredStyle: .actionSheet
        )
        sheet.addAction(UIAlertAction(title: "Unrestrict", style: .default) { [weak self] _ in
            self?.unrestrict(profile)
        })
        sheet.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        if let popover = sheet.popoverPresentationController, let cell = collectionView.cellForItem(at: indexPath) {
            popover.sourceView = cell
            popover.sourceRect = cell.bounds
        }
        present(sheet, animated: true)
    }

    private func unrestrict(_ profile: RestrictedProfile) {
        Task { [weak self] in
            guard let self else { return }
            do {
                try await viewModel.unrestrict(profile)
            } catch {
                let alert = UIAlertController(title: nil, message: "Couldn't unrestrict @\(profile.handle). Try again.", preferredStyle: .alert)
                alert.addAction(UIAlertAction(title: "OK", style: .default))
                present(alert, animated: true)
            }
        }
    }
}

extension RestrictedAccountsViewController: UICollectionViewDelegate {
    func collectionView(_ collectionView: UICollectionView, shouldHighlightItemAt indexPath: IndexPath) -> Bool {
        switch dataSource.itemIdentifier(for: indexPath) {
        case .profile, .failed: true
        default: false
        }
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        switch dataSource.itemIdentifier(for: indexPath) {
        case .profile(let profile): confirmUnrestrict(profile, from: indexPath)
        case .failed: Task { await viewModel.load() }
        default: break
        }
    }
}
