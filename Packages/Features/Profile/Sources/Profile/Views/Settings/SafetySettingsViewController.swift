import DesignSystem
import UIKit

/// Settings → Safety and Interactions for the active profile: the screens
/// that exist (Blocked Accounts, #389) as rows, the rest under Coming Soon.
///
/// Rows are injected as titled factories so later slices (account status,
/// #390) add a line without touching this screen's logic.
final class SafetySettingsViewController: UIViewController {
    struct Destination {
        let title: String
        let symbolName: String
        let make: () -> UIViewController
    }

    private enum Item: Hashable {
        case destination(Int)
        case planned(String)
    }

    private let destinations: [Destination]
    private let planned: [String]
    private var collectionView: UICollectionView!
    private var dataSource: UICollectionViewDiffableDataSource<Int, Item>!

    init(destinations: [Destination], planned: [String]) {
        self.destinations = destinations
        self.planned = planned
        super.init(nibName: nil, bundle: nil)
        title = SettingsSection.safety.title
        hidesBottomBarWhenPushed = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidLoad() {
        super.viewDidLoad()
        navigationItem.largeTitleDisplayMode = .never
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

        let registration = UICollectionView.CellRegistration<UICollectionViewListCell, Item> { [weak self] cell, _, item in
            guard let self else { return }
            var content = UIListContentConfiguration.cell()
            switch item {
            case .destination(let index):
                content.text = destinations[index].title
                content.image = UIImage(systemName: destinations[index].symbolName)
                content.imageProperties.tintColor = .label
                cell.accessories = [.disclosureIndicator()]
            case .planned(let title):
                content.text = title
                content.textProperties.color = .secondaryLabel
                cell.accessories = []
            }
            cell.contentConfiguration = content
        }
        dataSource = UICollectionViewDiffableDataSource<Int, Item>(collectionView: collectionView) { collectionView, indexPath, item in
            collectionView.dequeueConfiguredReusableCell(using: registration, for: indexPath, item: item)
        }
        let header = UICollectionView.SupplementaryRegistration<UICollectionViewListCell>(
            elementKind: UICollectionView.elementKindSectionHeader
        ) { view, _, indexPath in
            var content = UIListContentConfiguration.header()
            content.text = indexPath.section == 1 ? "Coming Soon" : nil
            view.contentConfiguration = content
        }
        let footer = UICollectionView.SupplementaryRegistration<UICollectionViewListCell>(
            elementKind: UICollectionView.elementKindSectionFooter
        ) { view, _, indexPath in
            var content = UIListContentConfiguration.footer()
            content.text = indexPath.section == 1 ? "These need a server update and aren't available yet." : nil
            view.contentConfiguration = content
        }
        dataSource.supplementaryViewProvider = { collectionView, kind, indexPath in
            kind == UICollectionView.elementKindSectionHeader
                ? collectionView.dequeueConfiguredReusableSupplementary(using: header, for: indexPath)
                : collectionView.dequeueConfiguredReusableSupplementary(using: footer, for: indexPath)
        }

        var snapshot = NSDiffableDataSourceSnapshot<Int, Item>()
        snapshot.appendSections([0, 1])
        snapshot.appendItems(destinations.indices.map(Item.destination), toSection: 0)
        snapshot.appendItems(planned.map(Item.planned), toSection: 1)
        dataSource.apply(snapshot, animatingDifferences: false)
    }
}

extension SafetySettingsViewController: UICollectionViewDelegate {
    func collectionView(_ collectionView: UICollectionView, shouldHighlightItemAt indexPath: IndexPath) -> Bool {
        if case .destination = dataSource.itemIdentifier(for: indexPath) { return true }
        return false
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        if case .destination(let index) = dataSource.itemIdentifier(for: indexPath) {
            navigationController?.pushViewController(destinations[index].make(), animated: true)
        }
    }
}
