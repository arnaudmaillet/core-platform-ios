import CoreStorage
import DesignSystem
import UIKit

/// A settings page that can open another section (Family and Teens points at
/// Privacy, What You See…). `SettingsViewController` hands it the way.
@MainActor
protocol SettingsSectionLinking: AnyObject {
    var openSection: ((SettingsSection) -> Void)? { get set }
}

/// Settings → Family and Teens (#401): the protections an account aged 13–17
/// starts with, each opening the page that changes it. No switch turns them
/// all off at once (decided 2026-10-07): the server starts the profile
/// private, with messages from followers, location hidden, sensitive content
/// at Less and quiet hours from 22:00 to 07:00; the device adds a 60-minute
/// daily limit and no purchases (`TeenProtections`).
///
/// An adult sees the same list as what a teen account gets, without links.
final class FamilyAndTeensViewController: UIViewController, SettingsSectionLinking {
    enum Section: Hashable {
        case protections, supervision
    }

    /// One protection: what it is, what it does, and the page that changes it.
    struct Protection: Hashable {
        let title: String
        let detail: String
        let symbol: String
        let section: SettingsSection?
    }

    private enum Item: Hashable {
        case protection(Protection)
        case supervision
        case loading
    }

    var openSection: ((SettingsSection) -> Void)?
    private let isTeen: () async -> Bool
    private let screenTime: ScreenTimeStore
    /// Nil while the account is being read.
    private var teen: Bool?
    private var collectionView: UICollectionView!
    private var dataSource: UICollectionViewDiffableDataSource<Section, Item>!

    init(isTeen: @escaping () async -> Bool, screenTime: ScreenTimeStore = .standard) {
        self.isTeen = isTeen
        self.screenTime = screenTime
        super.init(nibName: nil, bundle: nil)
        title = SettingsSection.familyAndTeens.title
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
        Task { [weak self] in
            guard let self else { return }
            teen = await isTeen()
            applySnapshot()
        }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        // The daily limit may have changed in Time Management.
        if teen != nil { applySnapshot() }
    }

    // MARK: - Copy

    static func protections(dailyLimitMinutes: Int?) -> [Protection] {
        [
            Protection(title: "Private Account", detail: "The profile starts private: only approved followers see posts.",
                       symbol: "lock", section: .privacy),
            Protection(title: "Messages and Mentions", detail: "Only followers can send messages or mention you.",
                       symbol: "bubble.left.and.bubble.right", section: .privacy),
            Protection(title: "Location", detail: "Hidden on the map. When shared, only mutual friends see the city.",
                       symbol: "location.slash", section: .privacy),
            Protection(title: "Sensitive Content", detail: "Always Less until 18.",
                       symbol: "eye.slash", section: .whatYouSee),
            Protection(title: "Daily Limit", detail: dailyLimitMinutes.map { "A reminder after \($0) minutes a day on this iPhone." }
                       ?? "Off on this iPhone. It starts at \(TeenProtections.defaultDailyLimitMinutes) minutes.",
                       symbol: "hourglass", section: .activity),
            Protection(title: "Quiet Hours", detail: "No notifications from 22:00 to 07:00.",
                       symbol: "moon", section: .notifications),
            Protection(title: "Purchases", detail: "Off until 18: gems can't be bought or spent.",
                       symbol: "cart.badge.minus", section: nil),
        ]
    }

    static func header(_ section: Section, teen: Bool) -> String {
        switch section {
        case .protections: teen ? "Teen Protections" : "For Accounts Aged 13 to 17"
        case .supervision: "Parental Supervision"
        }
    }

    static func footer(_ section: Section, teen: Bool) -> String {
        switch section {
        case .protections:
            teen
                ? "Your account is 13 to 17, so these started on. Tap one to change it. Sensitive Content and purchases stay as they are until you turn 18."
                : "An account aged 13 to 17 starts with these on, from the date of birth given at sign-up. Your account is 18 or over, so they don't apply."
        case .supervision:
            "Linking a parent's account to see activity and set limits isn't available yet."
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
            case .protection(let protection):
                content.text = protection.title
                content.secondaryText = protection.detail
                content.image = UIImage(systemName: protection.symbol)
                content.imageProperties.tintColor = .label
                if teen == true, protection.section != nil { cell.accessories = [.disclosureIndicator()] }
            case .supervision:
                content = .cell()
                content.text = "Not Available Yet"
                content.textProperties.color = .secondaryLabel
            case .loading:
                content = .cell()
                content.text = "Loading…"
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
            guard let self else { return }
            var content = UIListContentConfiguration.header()
            content.text = dataSource.sectionIdentifier(for: indexPath.section).map { Self.header($0, teen: self.teen ?? false) }
            view.contentConfiguration = content
        }
        let footer = UICollectionView.SupplementaryRegistration<UICollectionViewListCell>(
            elementKind: UICollectionView.elementKindSectionFooter
        ) { [weak self] view, _, indexPath in
            guard let self else { return }
            var content = UIListContentConfiguration.footer()
            content.text = teen == nil ? nil
                : dataSource.sectionIdentifier(for: indexPath.section).map { Self.footer($0, teen: self.teen ?? false) }
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
        snapshot.appendSections([.protections])
        if teen == nil {
            snapshot.appendItems([.loading], toSection: .protections)
        } else {
            let protections = Self.protections(dailyLimitMinutes: screenTime.settings.dailyLimitMinutes)
            snapshot.appendItems(protections.map(Item.protection), toSection: .protections)
            snapshot.appendSections([.supervision])
            snapshot.appendItems([.supervision], toSection: .supervision)
        }
        snapshot.reconfigureItems(snapshot.itemIdentifiers)
        snapshot.reloadSections(snapshot.sectionIdentifiers)
        dataSource.apply(snapshot, animatingDifferences: false)
    }
}

extension FamilyAndTeensViewController: UICollectionViewDelegate {
    func collectionView(_ collectionView: UICollectionView, shouldHighlightItemAt indexPath: IndexPath) -> Bool {
        guard teen == true, case .protection(let protection) = dataSource.itemIdentifier(for: indexPath) else { return false }
        return protection.section != nil
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        guard teen == true, case .protection(let protection) = dataSource.itemIdentifier(for: indexPath),
              let section = protection.section else { return }
        openSection?(section)
    }
}
