import DesignSystem
import UIKit

/// Settings → Ads and Data (#395, backend #653): the consents on the account,
/// each with when it last changed, and what is still to come.
///
/// Marketing and analytics are switches, applied at once, withdrawn as easily
/// as given (GDPR Art. 7(3)). Processing the account's data is what the
/// service runs on, so it isn't a switch: the way to withdraw it is to delete
/// the account, and the row says so.
final class ConsentsViewController: UIViewController {
    private enum Section: Hashable {
        case consents, required, comingSoon
    }

    private enum Item: Hashable {
        case marketing, analytics
        case dataProcessing
        case loading, failed
        case planned(String)
    }

    static let planned = ["Personalised ads", "Why you see an ad"]

    private let manager: any AccountConsentManaging
    private let makeDeleteAccount: (() -> UIViewController?)?
    private var consents: AccountConsents?
    private var didFail = false
    private var collectionView: UICollectionView!
    private var dataSource: UICollectionViewDiffableDataSource<Section, Item>!

    init(manager: any AccountConsentManaging, makeDeleteAccount: (() -> UIViewController?)? = nil) {
        self.manager = manager
        self.makeDeleteAccount = makeDeleteAccount
        super.init(nibName: nil, bundle: nil)
        title = SettingsSection.adsAndData.title
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
        collectionView = UICollectionView(frame: view.bounds, collectionViewLayout: UICollectionViewCompositionalLayout.list(using: config))
        collectionView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        collectionView.prefersSoftTopEdge()
        collectionView.delegate = self
        view.addSubview(collectionView)
        configureDataSource()
        applySnapshot()
        load()
    }

    // MARK: - Copy

    private static func header(_ section: Section) -> String? {
        switch section {
        case .consents: "Your Consents"
        case .required: nil
        case .comingSoon: "Coming Soon"
        }
    }

    private static func footer(_ section: Section) -> String? {
        switch section {
        case .consents: "Change these at any time; each change is recorded with its date. They apply to every profile on your account."
        case .required: "Needed to run your account. To withdraw it, delete your account."
        case .comingSoon: "These arrive with ads in the app."
        }
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter
    }()

    /// "Given on 4 Oct 2026", "Withdrawn on 4 Oct 2026", "Not given".
    static func statusText(_ consent: AccountConsents.Consent) -> String {
        guard let changedAt = consent.changedAt else { return consent.isGiven ? "Given" : "Not given" }
        return "\(consent.isGiven ? "Given" : "Withdrawn") on \(dateFormatter.string(from: changedAt))"
    }

    // MARK: - Data

    private func load() {
        Task { [weak self] in
            guard let self else { return }
            do {
                consents = try await manager.consents()
                didFail = false
            } catch {
                didFail = true
            }
            applySnapshot()
        }
    }

    private func set(marketing: Bool? = nil, analytics: Bool? = nil, revert: @escaping () -> Void) {
        Task { [weak self] in
            guard let self else { return }
            do {
                consents = try await manager.updateConsents(marketing: marketing, analytics: analytics)
                HapticSelection().selectionChanged()
                reconfigure([.marketing, .analytics])
            } catch {
                revert()
                let alert = UIAlertController(title: nil, message: "Couldn't save that change. Try again.", preferredStyle: .alert)
                alert.addAction(UIAlertAction(title: "OK", style: .default))
                present(alert, animated: true)
            }
        }
    }

    // MARK: - List

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
            content.text = self?.dataSource.sectionIdentifier(for: indexPath.section).flatMap(Self.header)
            view.contentConfiguration = content
        }
        let footer = UICollectionView.SupplementaryRegistration<UICollectionViewListCell>(
            elementKind: UICollectionView.elementKindSectionFooter
        ) { [weak self] view, _, indexPath in
            var content = UIListContentConfiguration.footer()
            content.text = self?.dataSource.sectionIdentifier(for: indexPath.section).flatMap(Self.footer)
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
        snapshot.appendSections([.consents])
        if consents != nil {
            snapshot.appendItems([.marketing, .analytics], toSection: .consents)
            snapshot.appendSections([.required])
            snapshot.appendItems([.dataProcessing], toSection: .required)
        } else {
            snapshot.appendItems([didFail ? .failed : .loading], toSection: .consents)
        }
        snapshot.appendSections([.comingSoon])
        snapshot.appendItems(Self.planned.map(Item.planned), toSection: .comingSoon)
        snapshot.reconfigureItems(snapshot.itemIdentifiers)
        dataSource.apply(snapshot, animatingDifferences: false)
    }

    private func reconfigure(_ items: [Item]) {
        var snapshot = dataSource.snapshot()
        snapshot.reconfigureItems(items.filter { snapshot.indexOfItem($0) != nil })
        dataSource.apply(snapshot, animatingDifferences: false)
    }

    private func configure(_ cell: UICollectionViewListCell, for item: Item) {
        cell.accessories = []
        switch item {
        case .marketing:
            let consent = consents?.marketing ?? .init(isGiven: false)
            cell.contentConfiguration = Self.content("Marketing", detail: "Emails and offers about the app · \(Self.statusText(consent))", symbol: "envelope")
            cell.accessories = [toggle(isOn: consent.isGiven) { [weak self] isOn, revert in self?.set(marketing: isOn, revert: revert) }]
        case .analytics:
            let consent = consents?.analytics ?? .init(isGiven: false)
            cell.contentConfiguration = Self.content("Analytics", detail: "Usage statistics that help improve the app · \(Self.statusText(consent))", symbol: "chart.bar")
            cell.accessories = [toggle(isOn: consent.isGiven) { [weak self] isOn, revert in self?.set(analytics: isOn, revert: revert) }]
        case .dataProcessing:
            let consent = consents?.dataProcessing ?? .init(isGiven: true)
            cell.contentConfiguration = Self.content("Data Processing", detail: "To provide the service · \(Self.statusText(consent))", symbol: "server.rack")
            if makeDeleteAccount != nil { cell.accessories = [.disclosureIndicator()] }
        case .loading:
            var content = UIListContentConfiguration.cell()
            content.text = "Loading…"
            content.textProperties.color = .secondaryLabel
            cell.contentConfiguration = content
        case .failed:
            var content = UIListContentConfiguration.cell()
            content.text = "Couldn't load your consents. Tap to try again."
            content.textProperties.color = .secondaryLabel
            cell.contentConfiguration = content
        case .planned(let title):
            var content = UIListContentConfiguration.cell()
            content.text = title
            content.textProperties.color = .secondaryLabel
            cell.contentConfiguration = content
        }
    }

    private static func content(_ text: String, detail: String, symbol: String) -> UIListContentConfiguration {
        var content = UIListContentConfiguration.subtitleCell()
        content.text = text
        content.secondaryText = detail
        content.secondaryTextProperties.color = .secondaryLabel
        content.image = UIImage(systemName: symbol)
        content.imageProperties.tintColor = .label
        return content
    }

    /// A switch that applies at once; `onChange` gets a way to flip it back
    /// if the save fails.
    private func toggle(isOn: Bool, onChange: @escaping (Bool, @escaping () -> Void) -> Void) -> UICellAccessory {
        let toggle = UISwitch()
        toggle.isOn = isOn
        toggle.addAction(UIAction { [weak toggle] _ in
            guard let toggle else { return }
            let value = toggle.isOn
            onChange(value) { [weak toggle] in toggle?.setOn(!value, animated: true) }
        }, for: .valueChanged)
        return .customView(configuration: .init(customView: toggle, placement: .trailing(displayed: .always)))
    }
}

extension ConsentsViewController: UICollectionViewDelegate {
    func collectionView(_ collectionView: UICollectionView, shouldHighlightItemAt indexPath: IndexPath) -> Bool {
        switch dataSource.itemIdentifier(for: indexPath) {
        case .failed: true
        case .dataProcessing: makeDeleteAccount != nil
        default: false
        }
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        switch dataSource.itemIdentifier(for: indexPath) {
        case .failed:
            didFail = false
            applySnapshot()
            load()
        case .dataProcessing:
            if let screen = makeDeleteAccount?() {
                navigationController?.pushViewController(screen, animated: true)
            }
        default:
            break
        }
    }
}
