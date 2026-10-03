import DesignSystem
import UIKit

/// Settings → Privacy, for the active profile: Private Account (server-side,
/// `profile.v1.SetVisibility`, #388), the device-only list visibility screen,
/// and what is still coming.
final class PrivacySectionViewController: UIViewController {
    private enum Section: Hashable {
        case visibility, lists, comingSoon
    }

    private enum Item: Hashable {
        case privateAccount
        case loading
        case failed
        case hideLists
        case planned(String)
    }

    private static let planned = ["Follow requests", "Who can comment, mention and message you", "Location sharing"]

    private let viewModel: PrivacySectionViewModel
    private let makeListPrivacy: () -> UIViewController
    private var collectionView: UICollectionView!
    private var dataSource: UICollectionViewDiffableDataSource<Section, Item>!

    init(viewModel: PrivacySectionViewModel, makeListPrivacy: @escaping () -> UIViewController) {
        self.viewModel = viewModel
        self.makeListPrivacy = makeListPrivacy
        super.init(nibName: nil, bundle: nil)
        title = SettingsSection.privacy.title
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

    private static func footerText(_ section: Section) -> String? {
        switch section {
        case .visibility:
            "When your profile is private, only your followers can see your posts and your lists. Applies to this profile only."
        case .lists:
            nil
        case .comingSoon:
            "These need a server update and aren't available yet."
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
        collectionView.prefersClearTopEdge()
        collectionView.delegate = self
        view.addSubview(collectionView)
    }

    private func configureDataSource() {
        let registration = UICollectionView.CellRegistration<UICollectionViewListCell, Item> { [weak self] cell, _, item in
            self?.configure(cell, for: item)
        }
        dataSource = UICollectionViewDiffableDataSource<Section, Item>(collectionView: collectionView) { collectionView, indexPath, item in
            collectionView.dequeueConfiguredReusableCell(using: registration, for: indexPath, item: item)
        }
        let header = UICollectionView.SupplementaryRegistration<UICollectionViewListCell>(
            elementKind: UICollectionView.elementKindSectionHeader
        ) { [weak self] view, _, indexPath in
            var content = UIListContentConfiguration.header()
            content.text = self?.dataSource.sectionIdentifier(for: indexPath.section) == .comingSoon ? "Coming Soon" : nil
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

    private func configure(_ cell: UICollectionViewListCell, for item: Item) {
        var content = UIListContentConfiguration.cell()
        cell.accessories = []
        switch item {
        case .privateAccount:
            content.text = "Private Account"
            content.image = UIImage(systemName: "lock")
            content.imageProperties.tintColor = .label
            let toggle = UISwitch()
            if case .loaded(let isPrivate) = viewModel.phase { toggle.isOn = isPrivate }
            toggle.isEnabled = !viewModel.isSaving
            toggle.addAction(UIAction { [weak self] action in
                guard let toggle = action.sender as? UISwitch else { return }
                self?.setPrivate(toggle.isOn)
            }, for: .valueChanged)
            cell.accessories = [.customView(configuration: .init(customView: toggle, placement: .trailing(displayed: .always)))]
        case .loading:
            content.text = "Private Account"
            content.secondaryText = nil
            let spinner = UIActivityIndicatorView(style: .medium)
            spinner.startAnimating()
            cell.accessories = [.customView(configuration: .init(customView: spinner, placement: .trailing()))]
        case .failed:
            content.text = "Couldn't load your privacy setting. Tap to try again."
            content.textProperties.color = .secondaryLabel
        case .hideLists:
            content.text = "Followers and Following Lists"
            content.image = UIImage(systemName: "person.2")
            content.imageProperties.tintColor = .label
            cell.accessories = [.disclosureIndicator()]
        case .planned(let title):
            content.text = title
            content.textProperties.color = .secondaryLabel
        }
        cell.contentConfiguration = content
    }

    private func applySnapshot() {
        var snapshot = NSDiffableDataSourceSnapshot<Section, Item>()
        snapshot.appendSections([.visibility, .lists, .comingSoon])
        switch viewModel.phase {
        case .loading: snapshot.appendItems([.loading], toSection: .visibility)
        case .loaded: snapshot.appendItems([.privateAccount], toSection: .visibility)
        case .failed: snapshot.appendItems([.failed], toSection: .visibility)
        }
        snapshot.appendItems([.hideLists], toSection: .lists)
        snapshot.appendItems(Self.planned.map(Item.planned), toSection: .comingSoon)
        // The switch reads the phase and the saving flag at configuration.
        if case .loaded = viewModel.phase { snapshot.reconfigureItems([.privateAccount]) }
        dataSource.apply(snapshot, animatingDifferences: false)
    }

    private func setPrivate(_ isPrivate: Bool) {
        Task { [weak self] in
            guard let self else { return }
            do {
                try await viewModel.setPrivate(isPrivate)
            } catch {
                // Snap the switch back to what the server holds.
                applySnapshot()
                let alert = UIAlertController(title: nil, message: "Couldn't change your privacy setting. Try again.", preferredStyle: .alert)
                alert.addAction(UIAlertAction(title: "OK", style: .default))
                present(alert, animated: true)
            }
        }
    }
}

extension PrivacySectionViewController: UICollectionViewDelegate {
    func collectionView(_ collectionView: UICollectionView, shouldHighlightItemAt indexPath: IndexPath) -> Bool {
        switch dataSource.itemIdentifier(for: indexPath) {
        case .hideLists, .failed: true
        default: false
        }
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        switch dataSource.itemIdentifier(for: indexPath) {
        case .hideLists:
            navigationController?.pushViewController(makeListPrivacy(), animated: true)
        case .failed:
            Task { await viewModel.load() }
        default:
            break
        }
    }
}
