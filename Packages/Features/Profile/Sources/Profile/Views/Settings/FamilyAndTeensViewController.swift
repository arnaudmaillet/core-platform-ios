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
///
/// ⚠️ **AN UNREAD AGE IS NOT AN ADULT ONE (#799).** The age used to be read
/// as `(try? …isTeen) ?? false`, so a dropped connection told a 14-year-old
/// "Your account is 18 or over, so they don't apply" and took the links to
/// their protections away. Until the age is known, nothing age-dependent is
/// drawn — no header, no footer, no protections — and a failed read shows a
/// failed row with retry. Hiding beats guessing either way: "teen" would
/// misstate an adult's account just as surely, and this page changes nothing
/// by itself, so showing nothing costs only a tap on Retry.
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
        case failed
    }

    static let failedText = "Couldn't load your account's age. Tap to try again."

    var openSection: ((SettingsSection) -> Void)?
    /// The account's age bracket, read on arrival and from the failed row;
    /// its closure throws when the account can't be read.
    private let ageCheck: TeenAgeCheck
    private let screenTime: ScreenTimeStore
    private var age: Loadable<Bool> { ageCheck.age }
    /// True or false once known; nil while loading or after a failed read.
    private var teen: Bool? { age.content }
    private var collectionView: UICollectionView!
    private var dataSource: UICollectionViewDiffableDataSource<Section, Item>!

    init(isTeen: @escaping () async throws -> Bool, screenTime: ScreenTimeStore = .standard) {
        ageCheck = TeenAgeCheck(isTeen: isTeen)
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
        readAge()
    }

    /// Reads the age; a retry that fails again keeps the failed row and says
    /// so. A tap while a read runs sends nothing (`TeenAgeCheck`).
    private func readAge() {
        let isRetry = age.isFailed
        Task { [weak self] in
            guard let self else { return }
            let succeeded = await ageCheck.read()
            applySnapshot()
            if isRetry, !succeeded {
                Feedback.failure("Couldn't load your account's age", from: self)
            }
        }
    }

    /// The age as the page draws it: known, or failed — a read that throws
    /// is never folded into "adult". Pure, so the rule is pinned by tests.
    static func readAge(_ isTeen: () async throws -> Bool) async -> Loadable<Bool> {
        do {
            return .content(try await isTeen())
        } catch {
            return .failed(message: failedText)
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
            // Only a failed row is tapped to retry: VoiceOver says so (#799).
            cell.accessibilityTraits.remove(.button)
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
            case .failed:
                content = .cell()
                content.text = Self.failedText
                content.textProperties.color = .secondaryLabel
                cell.accessibilityTraits.insert(.button)
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
            // No age-dependent wording until the age is known (#799).
            content.text = self.teen.flatMap { teen in
                self.dataSource.sectionIdentifier(for: indexPath.section).map { Self.header($0, teen: teen) }
            }
            view.contentConfiguration = content
        }
        let footer = UICollectionView.SupplementaryRegistration<UICollectionViewListCell>(
            elementKind: UICollectionView.elementKindSectionFooter
        ) { [weak self] view, _, indexPath in
            guard let self else { return }
            var content = UIListContentConfiguration.footer()
            content.text = self.teen.flatMap { teen in
                self.dataSource.sectionIdentifier(for: indexPath.section).map { Self.footer($0, teen: teen) }
            }
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
        switch age {
        case .loading, .empty:
            snapshot.appendItems([.loading], toSection: .protections)
        case .failed:
            snapshot.appendItems([.failed], toSection: .protections)
        case .content:
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
        if case .failed = dataSource.itemIdentifier(for: indexPath) { return true }
        guard teen == true, case .protection(let protection) = dataSource.itemIdentifier(for: indexPath) else { return false }
        return protection.section != nil
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        if case .failed = dataSource.itemIdentifier(for: indexPath) { return readAge() }
        guard teen == true, case .protection(let protection) = dataSource.itemIdentifier(for: indexPath),
              let section = protection.section else { return }
        openSection?(section)
    }
}
