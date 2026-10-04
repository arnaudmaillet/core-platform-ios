import CoreStorage
import DesignSystem
import UIKit

/// Settings → Your Activity (#489): Time Management (a daily limit and break
/// reminders) and this iPhone's screen time for the last seven days.
/// Recently deleted and history clearing wait on the backend (#408).
///
/// Everything here is measured and stored on the device; the reminders are
/// raised by the app shell's `ScreenTimeCoordinator`.
final class YourActivityViewController: UIViewController {
    private enum Section: Hashable {
        case limits, usage, comingSoon
    }

    private enum Item: Hashable {
        case dailyLimit, breakReminder
        case today, week
        case planned(String)
    }

    static let planned = ["Recently deleted", "Likes and history"]

    private let store: ScreenTimeStore
    private let calendar: Calendar
    private let now: () -> Date
    private var collectionView: UICollectionView!
    private var dataSource: UICollectionViewDiffableDataSource<Section, Item>!

    init(store: ScreenTimeStore = .standard, calendar: Calendar = .current, now: @escaping () -> Date = Date.init) {
        self.store = store
        self.calendar = calendar
        self.now = now
        super.init(nibName: nil, bundle: nil)
        title = SettingsSection.activity.title
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
            frame: view.bounds, collectionViewLayout: UICollectionViewCompositionalLayout.list(using: config)
        )
        collectionView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        collectionView.prefersSoftTopEdge()
        collectionView.delegate = self
        view.addSubview(collectionView)
        configureDataSource()
        applySnapshot()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        reconfigure([.today, .week])
    }

    // MARK: - Copy

    private static func header(_ section: Section) -> String {
        switch section {
        case .limits: "Time Management"
        case .usage: "Screen Time"
        case .comingSoon: "Coming Soon"
        }
    }

    private static func footer(_ section: Section) -> String {
        switch section {
        case .limits: "A reminder appears when you reach your daily limit, or after this long without a break. Applies to this iPhone."
        case .usage: "Time with the app open, measured on this iPhone. It is never sent anywhere."
        case .comingSoon: "These need a server update and aren't available yet."
        }
    }

    static func limitTitle(_ minutes: Int?) -> String {
        guard let minutes else { return "Off" }
        return ScreenTimeLedger.durationText(TimeInterval(minutes * 60))
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
            guard let section = self?.dataSource.sectionIdentifier(for: indexPath.section) else { return }
            var content = UIListContentConfiguration.header()
            content.text = Self.header(section)
            view.contentConfiguration = content
        }
        let footer = UICollectionView.SupplementaryRegistration<UICollectionViewListCell>(
            elementKind: UICollectionView.elementKindSectionFooter
        ) { [weak self] view, _, indexPath in
            guard let section = self?.dataSource.sectionIdentifier(for: indexPath.section) else { return }
            var content = UIListContentConfiguration.footer()
            content.text = Self.footer(section)
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
        snapshot.appendSections([.limits, .usage, .comingSoon])
        snapshot.appendItems([.dailyLimit, .breakReminder], toSection: .limits)
        snapshot.appendItems([.today, .week], toSection: .usage)
        snapshot.appendItems(Self.planned.map(Item.planned), toSection: .comingSoon)
        dataSource.apply(snapshot, animatingDifferences: false)
    }

    private func reconfigure(_ items: [Item]) {
        guard dataSource != nil else { return }
        var snapshot = dataSource.snapshot()
        snapshot.reconfigureItems(items.filter { snapshot.indexOfItem($0) != nil })
        dataSource.apply(snapshot, animatingDifferences: false)
    }

    private func configure(_ cell: UICollectionViewListCell, for item: Item) {
        cell.accessories = []
        let settings = store.settings
        switch item {
        case .dailyLimit:
            cell.contentConfiguration = Self.valueContent(
                "Daily Limit", symbol: "hourglass", value: Self.limitTitle(settings.dailyLimitMinutes)
            )
            cell.accessories = [menuAccessory(
                choices: ScreenTimeSettings.dailyLimitChoices, selected: settings.dailyLimitMinutes
            ) { [weak self] minutes in
                self?.store.updateSettings { $0.dailyLimitMinutes = minutes }
                self?.reconfigure([.dailyLimit])
            }]
        case .breakReminder:
            cell.contentConfiguration = Self.valueContent(
                "Break Reminder", symbol: "cup.and.saucer", value: Self.limitTitle(settings.breakReminderMinutes)
            )
            cell.accessories = [menuAccessory(
                choices: ScreenTimeSettings.breakChoices, selected: settings.breakReminderMinutes
            ) { [weak self] minutes in
                self?.store.updateSettings { $0.breakReminderMinutes = minutes }
                self?.reconfigure([.breakReminder])
            }]
        case .today:
            let seconds = store.ledger.seconds(on: now(), calendar: calendar)
            cell.contentConfiguration = Self.valueContent(
                "Today", symbol: "clock", value: ScreenTimeLedger.durationText(seconds)
            )
        case .week:
            let days = store.ledger.lastDays(7, endingOn: now(), calendar: calendar)
            cell.contentConfiguration = ScreenTimeWeekConfiguration(days: days, calendar: calendar)
        case .planned(let title):
            var content = UIListContentConfiguration.cell()
            content.text = title
            content.textProperties.color = .secondaryLabel
            cell.contentConfiguration = content
        }
    }

    private static func valueContent(_ text: String, symbol: String, value: String) -> UIListContentConfiguration {
        var content = UIListContentConfiguration.valueCell()
        content.text = text
        content.secondaryText = value
        content.image = UIImage(systemName: symbol)
        content.imageProperties.tintColor = .label
        return content
    }

    /// A pop-up menu over the row: Off, then each choice; the current one
    /// checked.
    private func menuAccessory(choices: [Int], selected: Int?, onChoose: @escaping (Int?) -> Void) -> UICellAccessory {
        let options: [Int?] = [nil] + choices.map { $0 }
        let actions = options.map { minutes in
            UIAction(title: Self.limitTitle(minutes), state: minutes == selected ? .on : .off) { _ in onChoose(minutes) }
        }
        return .popUpMenu(UIMenu(children: actions), displayed: .always)
    }
}

extension YourActivityViewController: UICollectionViewDelegate {
    func collectionView(_ collectionView: UICollectionView, shouldHighlightItemAt indexPath: IndexPath) -> Bool {
        switch dataSource.itemIdentifier(for: indexPath) {
        case .dailyLimit, .breakReminder: true
        default: false
        }
    }
}

/// The last seven days as bars, today last and in the accent colour.
struct ScreenTimeWeekConfiguration: UIContentConfiguration, Hashable {
    let days: [ScreenTimeDay]
    let calendar: Calendar

    struct ScreenTimeDay: Hashable {
        let day: Date
        let seconds: TimeInterval
    }

    init(days: [(day: Date, seconds: TimeInterval)], calendar: Calendar) {
        self.days = days.map { ScreenTimeDay(day: $0.day, seconds: $0.seconds) }
        self.calendar = calendar
    }

    func makeContentView() -> any UIView & UIContentView { ScreenTimeWeekView(configuration: self) }
    func updated(for state: any UIConfigurationState) -> ScreenTimeWeekConfiguration { self }
}

final class ScreenTimeWeekView: UIView, UIContentView {
    static let barAreaHeight: CGFloat = 80
    private let stack = UIStackView()

    var configuration: any UIContentConfiguration {
        didSet { apply() }
    }

    init(configuration: ScreenTimeWeekConfiguration) {
        self.configuration = configuration
        super.init(frame: .zero)
        stack.axis = .horizontal
        stack.distribution = .fillEqually
        stack.alignment = .bottom
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: layoutMarginsGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: layoutMarginsGuide.trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 16),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
            stack.heightAnchor.constraint(greaterThanOrEqualToConstant: Self.barAreaHeight)
        ])
        isAccessibilityElement = true
        apply()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func apply() {
        guard let configuration = configuration as? ScreenTimeWeekConfiguration else { return }
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let peak = max(configuration.days.map(\.seconds).max() ?? 0, 60)
        let formatter = DateFormatter()
        formatter.calendar = configuration.calendar
        formatter.setLocalizedDateFormatFromTemplate("EEEEE")
        let spoken = DateFormatter()
        spoken.calendar = configuration.calendar
        spoken.setLocalizedDateFormatFromTemplate("EEEE")
        for (index, day) in configuration.days.enumerated() {
            let isToday = index == configuration.days.count - 1
            let bar = UIView()
            bar.backgroundColor = isToday ? .tintColor : .tertiaryLabel
            bar.layer.cornerRadius = 3
            bar.layer.cornerCurve = .continuous
            let label = UILabel()
            label.text = formatter.string(from: day.day)
            label.font = .appFont(forTextStyle: .caption2)
            label.adjustsFontForContentSizeCategory = true
            label.textColor = isToday ? .label : .secondaryLabel
            label.textAlignment = .center
            let column = UIStackView(arrangedSubviews: [bar, label])
            column.axis = .vertical
            column.alignment = .fill
            column.spacing = 6
            let height = max(2, Self.barAreaHeight * CGFloat(day.seconds / peak))
            bar.heightAnchor.constraint(equalToConstant: height).isActive = true
            stack.addArrangedSubview(column)
        }
        accessibilityLabel = "Last 7 days"
        accessibilityValue = configuration.days.map {
            "\(spoken.string(from: $0.day)): \(ScreenTimeLedger.durationText($0.seconds))"
        }.joined(separator: ", ")
    }
}
