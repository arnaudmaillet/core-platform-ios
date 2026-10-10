import CoreNetworking
import DesignSystem
import UIKit
import UserNotifications

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
        /// iOS's own permission (#651): asked here, never in a pop-up of its own.
        case system
        case pause, push, quiet, comingSoon
    }

    enum Item: Hashable {
        /// iOS hasn't said yet: a bone holds the permission row's slot, so
        /// the list doesn't shift when the answer lands.
        case permissionPending
        /// Permission not asked yet, or only provisional (quiet delivery to
        /// Notification Center): asks for the full one.
        case allow
        /// Permission refused: iOS Settings is the only way back.
        case turnOnInSettings
        /// Permission given: the slot says so, rather than vanishing, and
        /// leads to iOS Settings, where it can be changed.
        case allowed
        case pause
        case category(NotificationCategory)
        case quietSwitch
        case quietStart, quietEnd
        case planned(String)
        /// A row-shaped bone while the preferences load (charter P8).
        case skeleton(Int)
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
    /// Why the last load failed, kept beside `.failed` so the failed row
    /// can say "You’re offline" when that is the cause (#794). Set before
    /// the phase, so the redraw `.failed` triggers already reads it.
    private var loadFailure: NetworkFailure?
    private var isSaving = false
    /// iOS's notification permission for this app, read on every appearance —
    /// it changes in iOS Settings, behind this screen's back.
    private var systemPermission: UNAuthorizationStatus? {
        didSet { applySnapshot() }
    }
    private var collectionView: UICollectionView!
    private var dataSource: UICollectionViewDiffableDataSource<Section, Item>!
    /// How many bones the list last drew: when that drops, the redraw
    /// cross-fades out of them (P10).
    private var skeletonCount = 0

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

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        readSystemPermission()
    }

    private func readSystemPermission() {
        Task { [weak self] in
            let settings = await UNUserNotificationCenter.current().notificationSettings()
            self?.systemPermission = settings.authorizationStatus
        }
    }

    /// The system prompt, from the viewer's own tap. Granted, this install asks
    /// APNs for its token, and the app registers it with the notification
    /// service (`AppDelegate` → `PushNotifications`).
    private func requestPermission() {
        Task { [weak self] in
            let granted = (try? await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .badge, .sound])) ?? false
            if granted { UIApplication.shared.registerForRemoteNotifications() }
            self?.readSystemPermission()
        }
    }

    private func openSystemSettings() {
        guard let url = URL(string: UIApplication.openNotificationSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }

    private func load() {
        phase = .loading
        Task { [weak self] in
            guard let self else { return }
            do {
                phase = .loaded(try await manager.notificationPreferences())
            } catch {
                loadFailure = NetworkFailure.of(error)
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
        case .system, .pause: nil
        case .push: "Push Notifications"
        case .quiet: "Quiet Hours"
        case .comingSoon: "Coming Soon"
        }
    }

    func footer(_ section: Section) -> String? {
        switch section {
        case .system:
            return Self.systemFooter(permission: systemPermission)
        case .pause:
            if case .loaded(let preferences) = phase, let until = preferences.pausedUntil {
                return "Paused until \(Self.timeFormatter.string(from: until))."
            }
            return "Stops every push for a while, up to 8 hours."
        case .push:
            return "Applies to this profile."
        case .quiet:
            return "No pushes between these times, in this iPhone's time zone."
        case .comingSoon:
            return "This needs a server update and isn't available yet."
        }
    }

    /// The permission section's footer: the pitch only while there is
    /// something to ask for; once allowed, where it is changed.
    static func systemFooter(permission: UNAuthorizationStatus?) -> String {
        switch Self.permissionRow(permission) {
        case .turnOnInSettings: "Notifications are turned off for this app in iOS Settings."
        case .allowed: "Notifications are on for this app. Choose which ones you get below."
        default: "Get a notification when someone likes, comments, mentions or follows you."
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
            case .allow:
                content.text = "Allow Notifications"
                content.image = UIImage(systemName: "bell.badge")
                content.textProperties.color = .tintColor
            case .turnOnInSettings:
                content.text = "Turn On in Settings"
                content.image = UIImage(systemName: "gear")
                content.textProperties.color = .tintColor
            case .allowed:
                content = .valueCell()
                content.text = "Notifications"
                content.secondaryText = "Allowed"
                content.image = UIImage(systemName: "bell.badge")
                content.imageProperties.tintColor = .label
                cell.accessories = [.disclosureIndicator()]
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
            case .permissionPending, .skeleton:
                // Drawn by `SettingsSkeletonRowCell`.
                break
            case .failed:
                // "You’re offline…" when that is why (#794).
                content.text = FailureCopy.row(
                    for: loadFailure, fallback: "Couldn't load your notification settings. Tap to try again."
                )
                content.textProperties.color = .secondaryLabel
            }
            cell.contentConfiguration = content
        }
        let skeletonRegistration = UICollectionView.CellRegistration<SettingsSkeletonRowCell, Item> { cell, _, item in
            cell.configure(redacting: Self.placeholder(for: item))
        }
        dataSource = UICollectionViewDiffableDataSource<Section, Item>(collectionView: collectionView) { collectionView, indexPath, item in
            switch item {
            case .permissionPending, .skeleton:
                collectionView.dequeueConfiguredReusableCell(using: skeletonRegistration, for: indexPath, item: item)
            default:
                collectionView.dequeueConfiguredReusableCell(using: registration, for: indexPath, item: item)
            }
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
        let layout = Self.layout(permission: systemPermission, phase: phase)
        for (section, items) in layout {
            snapshot.appendSections([section])
            snapshot.appendItems(items, toSection: section)
        }
        if case .loaded = phase {
            snapshot.reconfigureItems(snapshot.itemIdentifiers)
        }
        snapshot.reloadSections(snapshot.sectionIdentifiers.filter { $0 != .push })

        let previousSkeletonCount = skeletonCount
        skeletonCount = layout.flatMap { $0.1 }.filter(Self.isSkeleton).count
        if skeletonCount < previousSkeletonCount {
            collectionView.crossfadeSkeleton { [dataSource, snapshot] in
                dataSource?.apply(snapshot, animatingDifferences: false)
            }
        } else {
            dataSource.apply(snapshot, animatingDifferences: false)
        }
    }

    /// The screen's sections and rows. The permission row's slot is there
    /// from the first frame — a bone until iOS answers (nil), then the row for
    /// that answer — so the read never inserts a row above the list and
    /// pushes it down. While the preferences load, Pause All and the push
    /// categories are bones in their own places.
    static func layout(permission: UNAuthorizationStatus?, phase: Phase) -> [(Section, [Item])] {
        var layout: [(Section, [Item])] = [(.system, [permissionRow(permission)])]
        switch phase {
        case .loading:
            layout.append((.pause, [.skeleton(0)]))
            layout.append((.push, NotificationCategory.allCases.indices.map { .skeleton($0 + 1) }))
        case .failed:
            layout.append((.pause, [.failed]))
        case .loaded(let preferences):
            layout.append((.pause, [.pause]))
            layout.append((.push, NotificationCategory.allCases.map(Item.category)))
            layout.append((.quiet, [.quietSwitch] + (preferences.quietHours == nil ? [] : [.quietStart, .quietEnd])))
            layout.append((.comingSoon, Self.planned.map(Item.planned)))
        }
        return layout
    }

    /// The one row in the permission slot for iOS's answer (nil: not yet).
    static func permissionRow(_ permission: UNAuthorizationStatus?) -> Item {
        switch permission {
        case nil: .permissionPending
        case .notDetermined?, .provisional?: .allow
        case .denied?: .turnOnInSettings
        default: .allowed
        }
    }

    private static func isSkeleton(_ item: Item) -> Bool {
        switch item {
        case .permissionPending, .skeleton: true
        default: false
        }
    }

    /// The row a bone stands for, with sample words; only the bones' widths
    /// come from them.
    private static func placeholder(for item: Item) -> UIListContentConfiguration {
        switch item {
        case .permissionPending:
            var content = UIListContentConfiguration.cell()
            content.text = "Allow Notifications"
            content.image = UIImage(systemName: "bell.badge")
            return content
        case .skeleton(0):
            var content = UIListContentConfiguration.valueCell()
            content.text = "Pause All"
            content.image = UIImage(systemName: "bell.slash")
            return content
        case .skeleton(let index):
            var content = UIListContentConfiguration.cell()
            content.text = index.isMultiple(of: 2) ? "New followers" : "Comments and replies"
            return content
        default:
            return .cell()
        }
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
        switch dataSource.itemIdentifier(for: indexPath) {
        case .failed, .allow, .turnOnInSettings, .allowed: true
        default: false
        }
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        switch dataSource.itemIdentifier(for: indexPath) {
        case .failed: load()
        case .allow: requestPermission()
        case .turnOnInSettings, .allowed: openSystemSettings()
        default: break
        }
    }
}
