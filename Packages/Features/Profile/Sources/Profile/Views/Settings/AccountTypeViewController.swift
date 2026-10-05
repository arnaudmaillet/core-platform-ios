import DesignSystem
import UIKit

/// Edit Profile → Account Type (#415, backend #734): Personal, Creator or
/// Business. The type is public on the profile; a business also shows its
/// category and a contact card. Not optimistic.
final class AccountTypeViewController: UIViewController {
    enum Phase: Equatable {
        case loading
        case loaded(AccountType, BusinessContact?)
        case failed
    }

    enum Section: Hashable {
        case type, contact
    }

    enum ContactField: Hashable, CaseIterable {
        case category, email, phone

        var title: String {
            switch self {
            case .category: "Category"
            case .email: "Email"
            case .phone: "Phone"
            }
        }

        var placeholder: String {
            switch self {
            case .category: "Bakery, Musician…"
            case .email: "hello@example.com"
            case .phone: "+33 6 12 34 56 78"
            }
        }
    }

    private enum Item: Hashable {
        case type(AccountType)
        case contact(ContactField)
        case loading
        case failed
    }

    private let manager: any AccountTypeManaging
    private var phase: Phase = .loading {
        didSet { applySnapshot() }
    }
    private var isSaving = false
    private var collectionView: UICollectionView!
    private var dataSource: UICollectionViewDiffableDataSource<Section, Item>!

    init(manager: any AccountTypeManaging) {
        self.manager = manager
        super.init(nibName: nil, bundle: nil)
        title = "Account Type"
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
        configureDataSource()
        applySnapshot()
        load()
    }

    private func load() {
        phase = .loading
        Task { [weak self] in
            guard let self else { return }
            do {
                let current = try await manager.accountType()
                phase = .loaded(current.type, current.contact)
            } catch {
                phase = .failed
            }
        }
    }

    static func footer(_ section: Section, type: AccountType?) -> String? {
        switch section {
        case .type:
            type == .bot ? AccountType.bot.detail : "Everyone can see your account type. Applies to this profile only."
        case .contact:
            "Shown on your profile to everyone. The category is required; email and phone are optional."
        }
    }

    // MARK: - List

    private func configureDataSource() {
        let registration = UICollectionView.CellRegistration<UICollectionViewListCell, Item> { [weak self] cell, _, item in
            guard let self else { return }
            cell.accessories = []
            var content = UIListContentConfiguration.subtitleCell()
            content.secondaryTextProperties.color = .secondaryLabel
            switch item {
            case .type(let type):
                content.text = type.title
                content.secondaryText = type.detail
                if case .loaded(let current, _) = phase {
                    if current == type { cell.accessories = [.checkmark()] }
                    content.textProperties.color = current == .bot ? .secondaryLabel : .label
                }
            case .contact(let field):
                content = .valueCell()
                content.text = field.title
                if case .loaded(_, let contact) = phase {
                    let value = switch field {
                    case .category: contact?.category
                    case .email: contact?.email
                    case .phone: contact?.phone
                    }
                    content.secondaryText = (value?.isEmpty ?? true) ? "Add" : value
                }
                cell.accessories = [.disclosureIndicator()]
            case .loading:
                content = .cell()
                content.text = "Loading…"
                content.textProperties.color = .secondaryLabel
            case .failed:
                content = .cell()
                content.text = "Couldn't load your account type. Tap to try again."
                content.textProperties.color = .secondaryLabel
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
            content.text = self?.dataSource.sectionIdentifier(for: indexPath.section) == .contact ? "Contact Card" : nil
            view.contentConfiguration = content
        }
        let footer = UICollectionView.SupplementaryRegistration<UICollectionViewListCell>(
            elementKind: UICollectionView.elementKindSectionFooter
        ) { [weak self] view, _, indexPath in
            guard let self else { return }
            var content = UIListContentConfiguration.footer()
            let type: AccountType? = if case .loaded(let current, _) = phase { current } else { nil }
            content.text = dataSource.sectionIdentifier(for: indexPath.section).flatMap { Self.footer($0, type: type) }
            view.contentConfiguration = content
        }
        dataSource.supplementaryViewProvider = { collectionView, kind, indexPath in
            kind == UICollectionView.elementKindSectionHeader
                ? collectionView.dequeueConfiguredReusableSupplementary(using: header, for: indexPath)
                : collectionView.dequeueConfiguredReusableSupplementary(using: footer, for: indexPath)
        }
    }

    private func applySnapshot() {
        guard dataSource != nil else { return }
        var snapshot = NSDiffableDataSourceSnapshot<Section, Item>()
        snapshot.appendSections([.type])
        switch phase {
        case .loading:
            snapshot.appendItems([.loading], toSection: .type)
        case .failed:
            snapshot.appendItems([.failed], toSection: .type)
        case .loaded(let type, _):
            let types = type == .bot ? [AccountType.bot] : AccountType.choices
            snapshot.appendItems(types.map(Item.type), toSection: .type)
            if type == .business {
                snapshot.appendSections([.contact])
                snapshot.appendItems(ContactField.allCases.map(Item.contact), toSection: .contact)
            }
            snapshot.reconfigureItems(snapshot.itemIdentifiers)
        }
        snapshot.reloadSections(snapshot.sectionIdentifiers)
        dataSource.apply(snapshot, animatingDifferences: false)
    }

    // MARK: - Changes

    private func save(_ type: AccountType, contact: BusinessContact?) {
        guard !isSaving else { return }
        isSaving = true
        Task { [weak self] in
            guard let self else { return }
            do {
                try await manager.setAccountType(type, contact: contact)
                phase = .loaded(type, type == .business ? contact : nil)
                HapticSelection().selectionChanged()
            } catch {
                let message: String = switch error as? AccountTypeError {
                case .invalidContact: "Check your contact card: the category is required, and the email and phone must be valid."
                default: "Couldn't change your account type. Try again."
                }
                let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
                alert.addAction(UIAlertAction(title: "OK", style: .default))
                present(alert, animated: true)
            }
            isSaving = false
        }
    }

    private func choose(_ type: AccountType) {
        guard case .loaded(let current, _) = phase, current != type, current != .bot else { return }
        switch (current, type) {
        case (_, .business):
            // A business needs its category before it can be one.
            ask(.category, current: "") { [weak self] category in
                self?.save(.business, contact: BusinessContact(category: category))
            }
        case (.business, _):
            let sheet = UIAlertController(
                title: "Switch to \(type.title)?",
                message: "Your contact card will be removed from your profile.",
                preferredStyle: .actionSheet
            )
            sheet.addAction(UIAlertAction(title: "Switch", style: .destructive) { [weak self] _ in
                self?.save(type, contact: nil)
            })
            sheet.addAction(UIAlertAction(title: "Cancel", style: .cancel))
            if let popover = sheet.popoverPresentationController {
                popover.sourceView = view
                popover.sourceRect = CGRect(x: view.bounds.midX, y: view.bounds.midY, width: 0, height: 0)
                popover.permittedArrowDirections = []
            }
            present(sheet, animated: true)
        default:
            save(type, contact: nil)
        }
    }

    private func edit(_ field: ContactField) {
        guard case .loaded(.business, let contact) = phase, var card = contact else { return }
        let current = switch field {
        case .category: card.category
        case .email: card.email
        case .phone: card.phone
        }
        ask(field, current: current) { [weak self] value in
            switch field {
            case .category: card.category = value
            case .email: card.email = value
            case .phone: card.phone = value
            }
            self?.save(.business, contact: card)
        }
    }

    /// A one-field alert. The category can't be left empty.
    private func ask(_ field: ContactField, current: String, then: @escaping (String) -> Void) {
        let alert = UIAlertController(title: field.title, message: nil, preferredStyle: .alert)
        alert.addTextField { text in
            text.text = current
            text.placeholder = field.placeholder
            text.keyboardType = switch field {
            case .email: .emailAddress
            case .phone: .phonePad
            case .category: .default
            }
            text.autocapitalizationType = field == .category ? .words : .none
        }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Save", style: .default) { [weak alert] _ in
            let value = (alert?.textFields?.first?.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if field == .category, !BusinessContact(category: value).isValid { return }
            then(value)
        })
        present(alert, animated: true)
    }
}

extension AccountTypeViewController: UICollectionViewDelegate {
    func collectionView(_ collectionView: UICollectionView, shouldHighlightItemAt indexPath: IndexPath) -> Bool {
        switch dataSource.itemIdentifier(for: indexPath) {
        case .type(let type): type != .bot
        case .contact, .failed: true
        default: false
        }
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        switch dataSource.itemIdentifier(for: indexPath) {
        case .type(let type): choose(type)
        case .contact(let field): edit(field)
        case .failed: load()
        default: break
        }
    }
}
