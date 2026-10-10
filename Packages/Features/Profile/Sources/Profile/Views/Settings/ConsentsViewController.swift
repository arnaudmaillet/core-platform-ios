import DesignSystem
import UIKit

/// Settings → Ads and Data (#395, backend #653): the consents on the account,
/// each with when it last changed, and what is still to come.
///
/// Marketing and analytics are switches, applied at once, withdrawn as easily
/// as given (GDPR Art. 7(3)), one change at a time (`ConsentsViewModel`).
/// Processing the account's data is what the
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

    private let viewModel: ConsentsViewModel
    private let makeDeleteAccount: (() -> UIViewController?)?
    /// One switch per consent, kept across redraws: a save in flight
    /// disables it and a failed one flips it back, on the switch the viewer
    /// touched rather than on a fresh one swapped in mid-animation.
    private lazy var marketingSwitch = makeSwitch(for: .marketing)
    private lazy var analyticsSwitch = makeSwitch(for: .analytics)
    private var collectionView: UICollectionView!
    private var dataSource: UICollectionViewDiffableDataSource<Section, Item>!

    init(manager: any AccountConsentManaging, makeDeleteAccount: (() -> UIViewController?)? = nil) {
        self.viewModel = ConsentsViewModel(manager: manager)
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
        viewModel.onChange = { [weak self] in self?.applySnapshot() }
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
        Task { [weak self] in await self?.viewModel.load() }
    }

    /// The model rolls the consent back on failure; the redraw it triggers
    /// flips the switch back.
    private func set(_ consent: ConsentsViewModel.Consent, to isGiven: Bool) {
        Task { [weak self] in
            guard let self else { return }
            switch await viewModel.set(consent, to: isGiven) {
            case .saved:
                HapticSelection().selectionChanged()
            case .ignored:
                // A switch flipped in the instant before it was disabled.
                applySnapshot()
            case .failed:
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
        switch viewModel.phase {
        case .loaded:
            snapshot.appendItems([.marketing, .analytics], toSection: .consents)
            snapshot.appendSections([.required])
            snapshot.appendItems([.dataProcessing], toSection: .required)
        case .loading:
            snapshot.appendItems([.loading], toSection: .consents)
        case .failed:
            snapshot.appendItems([.failed], toSection: .consents)
        }
        snapshot.appendSections([.comingSoon])
        snapshot.appendItems(Self.planned.map(Item.planned), toSection: .comingSoon)
        snapshot.reconfigureItems(snapshot.itemIdentifiers)
        dataSource.apply(snapshot, animatingDifferences: false)
    }

    private func configure(_ cell: UICollectionViewListCell, for item: Item) {
        cell.accessories = []
        switch item {
        case .marketing:
            let consent = viewModel.consents?.marketing ?? .init(isGiven: false)
            cell.contentConfiguration = Self.content("Marketing", detail: "Emails and offers about the app · \(Self.statusText(consent))", symbol: "envelope")
            cell.accessories = [accessory(marketingSwitch, for: .marketing)]
        case .analytics:
            let consent = viewModel.consents?.analytics ?? .init(isGiven: false)
            cell.contentConfiguration = Self.content("Analytics", detail: "Usage statistics that help improve the app · \(Self.statusText(consent))", symbol: "chart.bar")
            cell.accessories = [accessory(analyticsSwitch, for: .analytics)]
        case .dataProcessing:
            let consent = viewModel.consents?.dataProcessing ?? .init(isGiven: true)
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

    /// A switch that applies at once.
    private func makeSwitch(for consent: ConsentsViewModel.Consent) -> UISwitch {
        let toggle = UISwitch()
        toggle.addAction(UIAction { [weak self, weak toggle] _ in
            guard let toggle else { return }
            self?.set(consent, to: toggle.isOn)
        }, for: .valueChanged)
        return toggle
    }

    /// `toggle` brought up to date with the model — the change in flight, or
    /// the record (which is how a failed save flips it back) — and disabled
    /// while any change is saving.
    private func accessory(_ toggle: UISwitch, for consent: ConsentsViewModel.Consent) -> UICellAccessory {
        let isOn = viewModel.isGiven(consent)
        if toggle.isOn != isOn { toggle.setOn(isOn, animated: toggle.window != nil) }
        toggle.isEnabled = !viewModel.isSaving
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
