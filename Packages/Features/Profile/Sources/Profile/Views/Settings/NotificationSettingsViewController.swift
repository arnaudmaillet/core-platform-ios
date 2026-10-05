import DesignSystem
import UIKit

/// Settings → Notifications (#392, backend #725): pause everything, push per
/// category and quiet hours, for the active profile. Saved on the server,
/// which decides each push from them. Not optimistic.
final class NotificationSettingsViewController: UIViewController {
    enum Phase: Equatable {
        case loading
        case loaded(NotificationPreferences)
        case failed
    }

    enum Section: Hashable {
        case pause, push, quiet, comingSoon
    }

    private enum Item: Hashable {
        case pause
        case category(NotificationCategory)
        case quietSwitch
        case quietStart, quietEnd
        case planned(String)
        case loading
        case failed
    }

    /// At most 8 h on the server.
    static let pauseChoices: [(title: String, minutes: Int)] = [
        ("15 Minutes", 15), ("1 Hour", 60), ("2 Hours", 120), ("4 Hours", 240), ("8 Hours", 480)
    ]
    static let planned = ["Email notifications"]

    private let manager: any NotificationPreferencesManaging
    private let now: () -> Date
    private var phase: Phase = .loading {
        didSet { applySnapshot() }
    }
    private var isSaving = false
    private var collectionView: UICollectionView!
    private var dataSource: UICollectionViewDiffableDataSource<Section, Item>!

    init(manager: any NotificationPreferencesManaging, now: @escaping () -> Date = Date.init) {
        self.manager = manager
        self.now = now
        super.init(nibName: nil, bundle: nil)
        title = SettingsSection.notifications.title
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
                phase = .loaded(try await manager.notificationPreferences())
            } catch {
                phase = .failed
            }
        }
    }

    // MARK: - Copy

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter
    }()

    static func header(_ section: Section) -> String? {
        switch section {
        case .pause: nil
        case .push: "Push Notifications"
        case .quiet: "Quiet Hours"
        case .comingSoon: "Coming Soon"
        }
    }

    func footer(_ section: Section) -> String? {
        switch section {
        case .pause:
            if case .loaded(let preferences) = phase, let until = preferences.pausedUntil {
                return "Paused until \(Self.timeFormatter.string(from: until))."
            }
            return "Stops every push for a while, up to 8 hours."
        case .push:
            return "Applies to this profile. This app doesn't receive push notifications yet; your choices are saved and will apply when it does."
        case .quiet:
            return "No pushes between these times, in this iPhone's time zone."
        case .comingSoon:
            return "This needs a server update and isn't available yet."
        }
    }

    /// "22:00" style text for minutes after midnight, in the locale's format.
    static func timeText(minutes: Int) -> String {
        var components = DateComponents()
        components.hour = minutes / 60
        components.minute = minutes % 60
        let date = Calendar.current.date(from: components) ?? Date()
        return timeFormatter.string(from: date)
    }

    // MARK: - List

    private func configureDataSource() {
        let registration = UICollectionView.CellRegistration<UICollectionViewListCell, Item> { [weak self] cell, _, item in
            guard let self else { return }
            cell.accessories = []
            var content = UIListContentConfiguration.cell()
            let preferences: NotificationPreferences? = if case .loaded(let current) = phase { current } else { nil }
            switch item {
            case .pause:
                content = .valueCell()
                content.text = "Pause All"
                content.image = UIImage(systemName: "bell.slash")
                content.imageProperties.tintColor = .label
                content.secondaryText = preferences?.pausedUntil == nil ? "Off" : "On"
                var actions = Self.pauseChoices.map { choice in
                    UIAction(title: choice.title) { [weak self] _ in self?.pause(minutes: choice.minutes) }
                }
                if preferences?.pausedUntil != nil {
                    actions.insert(UIAction(title: "Resume Now") { [weak self] _ in self?.resume() }, at: 0)
                }
                cell.accessories = [.popUpMenu(UIMenu(children: actions), displayed: .always)]
            case .category(let category):
                content.text = category.title
                cell.accessories = [switchAccessory(isOn: !(preferences?.mutedCategories.contains(category) ?? false)) { [weak self] isOn in
                    self?.apply(.push(category, isOn))
                }]
            case .quietSwitch:
                content.text = "Quiet Hours"
                content.image = UIImage(systemName: "moon")
                content.imageProperties.tintColor = .label
                cell.accessories = [switchAccessory(isOn: preferences?.quietHours != nil) { [weak self] isOn in
                    self?.apply(.quietHours(isOn ? QuietHours() : nil))
                }]
            case .quietStart, .quietEnd:
                let isStart = item == .quietStart
                content.text = isStart ? "From" : "To"
                cell.accessories = [timeAccessory(isStart: isStart, hours: preferences?.quietHours ?? QuietHours())]
            case .planned(let title):
                content.text = title
                content.textProperties.color = .secondaryLabel
            case .loading:
                content.text = "Loading…"
                content.textProperties.color = .secondaryLabel
            case .failed:
                content.text = "Couldn't load your notification settings. Tap to try again."
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
            content.text = self?.dataSource.sectionIdentifier(for: indexPath.section).flatMap(Self.header)
            view.contentConfiguration = content
        }
        let footer = UICollectionView.SupplementaryRegistration<UICollectionViewListCell>(
            elementKind: UICollectionView.elementKindSectionFooter
        ) { [weak self] view, _, indexPath in
            var content = UIListContentConfiguration.footer()
            content.text = self?.dataSource.sectionIdentifier(for: indexPath.section).flatMap { self?.footer($0) }
            view.contentConfiguration = content
        }
        dataSource.supplementaryViewProvider = { collectionView, kind, indexPath in
            kind == UICollectionView.elementKindSectionHeader
                ? collectionView.dequeueConfiguredReusableSupplementary(using: header, for: indexPath)
                : collectionView.dequeueConfiguredReusableSupplementary(using: footer, for: indexPath)
        }
    }

    private func switchAccessory(isOn: Bool, onChange: @escaping (Bool) -> Void) -> UICellAccessory {
        let toggle = UISwitch()
        toggle.isOn = isOn
        toggle.isEnabled = !isSaving
        toggle.addAction(UIAction { action in
            guard let toggle = action.sender as? UISwitch else { return }
            onChange(toggle.isOn)
        }, for: .valueChanged)
        return .customView(configuration: .init(customView: toggle, placement: .trailing(displayed: .always)))
    }

    /// A compact time picker; the change saves when the picker settles.
    private func timeAccessory(isStart: Bool, hours: QuietHours) -> UICellAccessory {
        let picker = UIDatePicker()
        picker.datePickerMode = .time
        picker.preferredDatePickerStyle = .compact
        picker.minuteInterval = 15
        let minutes = isStart ? hours.startMinute : hours.endMinute
        var components = DateComponents()
        components.hour = minutes / 60
        components.minute = minutes % 60
        picker.date = Calendar.current.date(from: components) ?? Date()
        picker.isEnabled = !isSaving
        picker.addAction(UIAction { [weak self] action in
            guard let picker = action.sender as? UIDatePicker else { return }
            let parts = Calendar.current.dateComponents([.hour, .minute], from: picker.date)
            let chosen = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
            var next = hours
            if isStart { next.startMinute = chosen } else { next.endMinute = chosen }
            self?.apply(.quietHours(next))
        }, for: .valueChanged)
        return .customView(configuration: .init(customView: picker, placement: .trailing(displayed: .always)))
    }

    private func applySnapshot() {
        guard dataSource != nil else { return }
        var snapshot = NSDiffableDataSourceSnapshot<Section, Item>()
        snapshot.appendSections([.pause])
        switch phase {
        case .loading:
            snapshot.appendItems([.loading], toSection: .pause)
        case .failed:
            snapshot.appendItems([.failed], toSection: .pause)
        case .loaded(let preferences):
            snapshot.appendItems([.pause], toSection: .pause)
            snapshot.appendSections([.push, .quiet, .comingSoon])
            snapshot.appendItems(NotificationCategory.allCases.map(Item.category), toSection: .push)
            snapshot.appendItems([.quietSwitch] + (preferences.quietHours == nil ? [] : [.quietStart, .quietEnd]), toSection: .quiet)
            snapshot.appendItems(Self.planned.map(Item.planned), toSection: .comingSoon)
            snapshot.reconfigureItems(snapshot.itemIdentifiers)
        }
        snapshot.reloadSections(snapshot.sectionIdentifiers.filter { $0 != .push })
        dataSource.apply(snapshot, animatingDifferences: false)
    }

    // MARK: - Changes

    private func apply(_ change: NotificationPreferencesChange) {
        guard case .loaded = phase, !isSaving else { return }
        isSaving = true
        Task { [weak self] in
            guard let self else { return }
            do {
                let next = try await manager.updateNotificationPreferences(change)
                isSaving = false
                phase = .loaded(next)
            } catch {
                isSaving = false
                applySnapshot()
                let alert = UIAlertController(title: nil, message: "Couldn't save your notification settings. Try again.", preferredStyle: .alert)
                alert.addAction(UIAlertAction(title: "OK", style: .default))
                present(alert, animated: true)
            }
        }
    }

    private func pause(minutes: Int) {
        apply(.pause(until: now().addingTimeInterval(TimeInterval(minutes) * 60)))
    }

    private func resume() {
        apply(.pause(until: nil))
    }
}

extension NotificationSettingsViewController: UICollectionViewDelegate {
    func collectionView(_ collectionView: UICollectionView, shouldHighlightItemAt indexPath: IndexPath) -> Bool {
        dataSource.itemIdentifier(for: indexPath) == .failed
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        if dataSource.itemIdentifier(for: indexPath) == .failed { load() }
    }
}
