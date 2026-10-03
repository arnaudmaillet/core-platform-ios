import DesignSystem
import UIKit

/// An editable list of muted terms — words or handles — for comments on
/// media (#410). Add from the field at the top, remove with a swipe.
final class MutedTermsViewController: UIViewController {
    struct Configuration {
        let title: String
        let placeholder: String
        let footer: String
        /// Turns typed text into the stored form ("" = reject).
        let normalize: (String) -> String
        /// How a stored term reads in the list.
        let display: (String) -> String
        let read: () -> [String]
        let write: ([String]) -> Void
    }

    private enum Item: Hashable {
        case field
        case term(String)
        case empty
    }

    private let configuration: Configuration
    private var terms: [String]
    private var collectionView: UICollectionView!
    private var dataSource: UICollectionViewDiffableDataSource<Int, Item>!
    private let field = UITextField()

    init(configuration: Configuration) {
        self.configuration = configuration
        self.terms = configuration.read()
        super.init(nibName: nil, bundle: nil)
        title = configuration.title
        hidesBottomBarWhenPushed = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidLoad() {
        super.viewDidLoad()
        navigationItem.largeTitleDisplayMode = .never
        var config = UICollectionLayoutListConfiguration(appearance: .insetGrouped)
        config.footerMode = .supplementary
        config.trailingSwipeActionsConfigurationProvider = { [weak self] indexPath in
            guard let self, case .term(let term) = dataSource.itemIdentifier(for: indexPath) else { return nil }
            let remove = UIContextualAction(style: .destructive, title: "Remove") { [weak self] _, _, done in
                self?.remove(term)
                done(true)
            }
            return UISwipeActionsConfiguration(actions: [remove])
        }
        collectionView = UICollectionView(
            frame: view.bounds,
            collectionViewLayout: UICollectionViewCompositionalLayout.list(using: config)
        )
        collectionView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        collectionView.prefersClearTopEdge()
        collectionView.keyboardDismissMode = .interactive
        view.addSubview(collectionView)

        field.placeholder = configuration.placeholder
        field.autocapitalizationType = .none
        field.autocorrectionType = .no
        field.returnKeyType = .done
        field.clearButtonMode = .whileEditing
        field.addAction(UIAction { [weak self] _ in self?.addFromField() }, for: .editingDidEndOnExit)

        let fieldRegistration = UICollectionView.CellRegistration<UICollectionViewListCell, Item> { [weak self] cell, _, _ in
            guard let self else { return }
            cell.contentConfiguration = nil
            field.translatesAutoresizingMaskIntoConstraints = false
            if field.superview !== cell.contentView {
                field.removeFromSuperview()
                cell.contentView.addSubview(field)
                let margins = cell.contentView.layoutMarginsGuide
                NSLayoutConstraint.activate([
                    field.leadingAnchor.constraint(equalTo: margins.leadingAnchor),
                    field.trailingAnchor.constraint(equalTo: margins.trailingAnchor),
                    field.topAnchor.constraint(equalTo: cell.contentView.topAnchor),
                    field.bottomAnchor.constraint(equalTo: cell.contentView.bottomAnchor),
                    field.heightAnchor.constraint(greaterThanOrEqualToConstant: 44)
                ])
            }
        }
        let termRegistration = UICollectionView.CellRegistration<UICollectionViewListCell, Item> { [weak self] cell, _, item in
            var content = UIListContentConfiguration.cell()
            switch item {
            case .term(let term): content.text = self?.configuration.display(term)
            case .empty:
                content.text = "Nothing muted yet."
                content.textProperties.color = .secondaryLabel
            case .field: break
            }
            cell.contentConfiguration = content
        }
        dataSource = UICollectionViewDiffableDataSource<Int, Item>(collectionView: collectionView) { collectionView, indexPath, item in
            item == .field
                ? collectionView.dequeueConfiguredReusableCell(using: fieldRegistration, for: indexPath, item: item)
                : collectionView.dequeueConfiguredReusableCell(using: termRegistration, for: indexPath, item: item)
        }
        let footer = UICollectionView.SupplementaryRegistration<UICollectionViewListCell>(
            elementKind: UICollectionView.elementKindSectionFooter
        ) { [weak self] view, _, indexPath in
            var content = UIListContentConfiguration.footer()
            content.text = indexPath.section == 0 ? self?.configuration.footer : nil
            view.contentConfiguration = content
        }
        dataSource.supplementaryViewProvider = { collectionView, _, indexPath in
            collectionView.dequeueConfiguredReusableSupplementary(using: footer, for: indexPath)
        }
        applySnapshot()
    }

    private func applySnapshot() {
        var snapshot = NSDiffableDataSourceSnapshot<Int, Item>()
        snapshot.appendSections([0, 1])
        snapshot.appendItems([.field], toSection: 0)
        snapshot.appendItems(terms.isEmpty ? [.empty] : terms.map(Item.term), toSection: 1)
        dataSource.apply(snapshot, animatingDifferences: view.window != nil)
    }

    private func addFromField() {
        let term = configuration.normalize(field.text ?? "")
        field.text = nil
        guard !term.isEmpty, !terms.contains(term) else { return }
        terms.insert(term, at: 0)
        configuration.write(terms)
        applySnapshot()
    }

    private func remove(_ term: String) {
        terms.removeAll { $0 == term }
        configuration.write(terms)
        applySnapshot()
    }
}
