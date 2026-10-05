import DesignSystem
import UIKit

/// Account Type → Request Verification (#415, backend #668): the badge's
/// category and 1 to 5 supporting links. Sent as one request; the screen
/// closes once the server has it, and Account Type then shows it pending.
final class VerificationRequestViewController: UIViewController {
    enum Section: Hashable {
        case category, links
    }

    private enum Item: Hashable {
        case category(VerificationCategory)
        case link(String)
        case addLink
    }

    private let manager: any VerificationRequesting
    private let onSubmitted: () -> Void
    private(set) var category: VerificationCategory?
    private(set) var links: [String] = []
    private var isSubmitting = false {
        didSet { updateSubmit() }
    }
    private var collectionView: UICollectionView!
    private var dataSource: UICollectionViewDiffableDataSource<Section, Item>!

    init(manager: any VerificationRequesting, onSubmitted: @escaping () -> Void) {
        self.manager = manager
        self.onSubmitted = onSubmitted
        super.init(nibName: nil, bundle: nil)
        title = "Request Verification"
        hidesBottomBarWhenPushed = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidLoad() {
        super.viewDidLoad()
        navigationItem.largeTitleDisplayMode = .never
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            title: "Submit", style: .prominent, target: self, action: #selector(submit)
        )
        var config = UICollectionLayoutListConfiguration(appearance: .insetGrouped)
        config.headerMode = .supplementary
        config.footerMode = .supplementary
        config.trailingSwipeActionsConfigurationProvider = { [weak self] indexPath in
            guard let self, case .link(let link) = dataSource.itemIdentifier(for: indexPath) else { return nil }
            let remove = UIContextualAction(style: .destructive, title: "Remove") { [weak self] _, _, done in
                self?.removeLink(link)
                done(true)
            }
            return UISwipeActionsConfiguration(actions: [remove])
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
        applySnapshot()
        updateSubmit()
    }

    /// Ready to send: a category and at least one link, nothing in flight.
    static func canSubmit(category: VerificationCategory?, links: [String], isSubmitting: Bool) -> Bool {
        category != nil && !links.isEmpty && links.count <= VerificationLink.maximumCount && !isSubmitting
    }

    static func footer(_ section: Section) -> String {
        switch section {
        case .category:
            "Choose what the badge should say about you."
        case .links:
            "Up to \(VerificationLink.maximumCount) links that confirm who you are: your official website, "
                + "news coverage, or a business registry entry. Don't send identity documents here."
        }
    }

    /// What the alert says when a request doesn't go.
    static func failureMessage(_ error: Error) -> String {
        switch error as? VerificationError {
        case .alreadyVerified: "This profile is already verified."
        case .alreadyPending: "You already have a request waiting for a decision."
        case .invalid: "Check your links: each one must be a web address, and you can send up to 5."
        default: "Couldn't send your request. Try again."
        }
    }

    private func updateSubmit() {
        navigationItem.rightBarButtonItem?.isEnabled = Self.canSubmit(
            category: category, links: links, isSubmitting: isSubmitting
        )
    }

    // MARK: - List

    private func configureDataSource() {
        let registration = UICollectionView.CellRegistration<UICollectionViewListCell, Item> { [weak self] cell, _, item in
            guard let self else { return }
            cell.accessories = []
            var content: UIListContentConfiguration
            switch item {
            case .category(let option):
                content = .subtitleCell()
                content.text = option.title
                content.secondaryText = option.detail
                content.secondaryTextProperties.color = .secondaryLabel
                if option == category { cell.accessories = [.checkmark()] }
            case .link(let link):
                content = .cell()
                content.text = link
                content.textProperties.numberOfLines = 1
                content.textProperties.lineBreakMode = .byTruncatingMiddle
                cell.accessories = [.delete(displayed: .always) { [weak self] in self?.removeLink(link) }]
            case .addLink:
                content = .cell()
                content.text = "Add Link"
                content.textProperties.color = .tintColor
                content.image = UIImage(systemName: "plus.circle.fill")
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
            content.text = self?.dataSource.sectionIdentifier(for: indexPath.section) == .links ? "Supporting Links" : "Category"
            view.contentConfiguration = content
        }
        let footer = UICollectionView.SupplementaryRegistration<UICollectionViewListCell>(
            elementKind: UICollectionView.elementKindSectionFooter
        ) { [weak self] view, _, indexPath in
            var content = UIListContentConfiguration.footer()
            content.text = self?.dataSource.sectionIdentifier(for: indexPath.section).map(Self.footer)
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
        snapshot.appendSections([.category, .links])
        snapshot.appendItems(VerificationCategory.allCases.map(Item.category), toSection: .category)
        snapshot.appendItems(links.map(Item.link), toSection: .links)
        if links.count < VerificationLink.maximumCount {
            snapshot.appendItems([.addLink], toSection: .links)
        }
        snapshot.reconfigureItems(VerificationCategory.allCases.map(Item.category))
        dataSource.apply(snapshot, animatingDifferences: true)
    }

    // MARK: - Changes

    private func choose(_ option: VerificationCategory) {
        category = option
        applySnapshot()
        updateSubmit()
    }

    private func removeLink(_ link: String) {
        links.removeAll { $0 == link }
        applySnapshot()
        updateSubmit()
    }

    private func addLink() {
        let alert = UIAlertController(title: "Add Link", message: nil, preferredStyle: .alert)
        alert.addTextField { text in
            text.placeholder = "example.com/about"
            text.keyboardType = .URL
            text.autocapitalizationType = .none
            text.autocorrectionType = .no
            text.textContentType = .URL
        }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Add", style: .default) { [weak self, weak alert] _ in
            guard let self else { return }
            guard let link = VerificationLink.normalized(alert?.textFields?.first?.text ?? "") else {
                return showAlert("That doesn't look like a web address.")
            }
            guard !links.contains(link) else { return }
            links.append(link)
            applySnapshot()
            updateSubmit()
        })
        present(alert, animated: true)
    }

    @objc private func submit() {
        guard let category, Self.canSubmit(category: category, links: links, isSubmitting: isSubmitting) else { return }
        isSubmitting = true
        let links = links
        Task { [weak self] in
            guard let self else { return }
            do {
                try await manager.requestVerification(category, links: links)
                isSubmitting = false
                onSubmitted()
                navigationController?.popViewController(animated: true)
            } catch {
                isSubmitting = false
                showAlert(Self.failureMessage(error))
            }
        }
    }

    private func showAlert(_ message: String) {
        let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }
}

extension VerificationRequestViewController: UICollectionViewDelegate {
    func collectionView(_ collectionView: UICollectionView, shouldHighlightItemAt indexPath: IndexPath) -> Bool {
        if case .link = dataSource.itemIdentifier(for: indexPath) { return false }
        return true
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        switch dataSource.itemIdentifier(for: indexPath) {
        case .category(let option): choose(option)
        case .addLink: addLink()
        default: break
        }
    }
}
