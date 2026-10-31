import CacheKit
import DesignSystem
import UIKit

/// Settings → App and Device → Storage (#409, #899): what the device cache
/// holds per category, memory included, with a clear for each and for all;
/// the storage limit; and Use Less Cellular Data. Everything is stored on
/// this iPhone and goes through the app's `CacheCoordinator`
/// (`StorageSettingsModel`).
final class StorageSettingsViewController: UIViewController {
    enum Section: Int, CaseIterable {
        case usage, limit, cellular
    }

    enum Item: Hashable {
        case category(CacheCategory)
        case total
        case clearAll
        case inUse
        case limit(CacheStorageLimit)
        case lessCellularData
    }

    private let model: StorageSettingsModel
    private var collectionView: UICollectionView!
    private var dataSource: UICollectionViewDiffableDataSource<Section, Item>!

    init(model: StorageSettingsModel) {
        self.model = model
        super.init(nibName: nil, bundle: nil)
        title = SettingsSection.storage.title
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
        model.onChange = { [weak self] in self?.reconfigureAll() }
        Task { await model.refresh() }
        #if DEBUG
        // `-storage-clear-all`: Clear All, as the confirmed sheet runs it, once
        // the screen has measured (#899). Lets a simulator check clear and
        // relaunch in one go, so no other run of the app can come in between.
        if ProcessInfo.processInfo.arguments.contains("-storage-clear-all") {
            Task { [model] in
                await model.refresh()
                print("[storage] clear all from \(model.report?.total ?? -1) bytes")
                await model.clear(nil)
                print("[storage] cleared, \(model.report?.total ?? -1) bytes left")
            }
        }
        #endif
    }

    // MARK: - Text

    static func header(_ section: Section) -> String {
        switch section {
        case .usage: "Storage"
        case .limit: "Storage Limit"
        case .cellular: "Cellular Data"
        }
    }

    static func footer(_ section: Section) -> String {
        switch section {
        case .usage: "Kept so posts, profiles and messages open instantly. Sizes include what the app holds in memory while it's open. Tap a category to clear it; anything on screen is kept until you leave it. Drafts, posts you're making, your settings and your account are never removed."
        case .limit: "Automatic sizes the cache for your iPhone and shrinks it when your iPhone is low on space. A lower limit removes the oldest downloads at once."
        case .cellular: "On cellular, nothing is downloaded ahead of time: images and videos load when you reach them, and videos stream at a lower quality."
        }
    }

    static func title(_ category: CacheCategory) -> String {
        switch category {
        case .images: "Images"
        case .videos: "Videos"
        case .sounds: "Music & Sounds"
        case .messages: "Messages"
        case .other: "Other"
        }
    }

    static func symbol(_ category: CacheCategory) -> String {
        switch category {
        case .images: "photo"
        case .videos: "play.rectangle"
        case .sounds: "music.note"
        case .messages: "bubble.left.and.bubble.right"
        case .other: "square.stack.3d.up"
        }
    }

    static func title(_ limit: CacheStorageLimit) -> String {
        switch limit {
        case .automatic: "Automatic"
        case .total(let bytes): gigabytes.string(fromByteCount: Int64(bytes))
        }
    }

    /// "0.5 GB", "1 GB", "2 GB": the limits read in one unit.
    private static let gigabytes: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = .useGB
        formatter.countStyle = .decimal
        return formatter
    }()

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
            content.text = self?.dataSource.sectionIdentifier(for: indexPath.section).map(Self.header)
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

    static func items(in section: Section) -> [Item] {
        switch section {
        case .usage: StorageSettingsModel.categories.map(Item.category) + [.total, .clearAll]
        case .limit: [.inUse] + CacheStorageLimit.choices.map(Item.limit)
        case .cellular: [.lessCellularData]
        }
    }

    private func applySnapshot() {
        var snapshot = NSDiffableDataSourceSnapshot<Section, Item>()
        for section in Section.allCases {
            snapshot.appendSections([section])
            snapshot.appendItems(Self.items(in: section), toSection: section)
        }
        dataSource.apply(snapshot, animatingDifferences: false)
    }

    private func reconfigureAll() {
        guard dataSource != nil else { return }
        var snapshot = dataSource.snapshot()
        snapshot.reconfigureItems(snapshot.itemIdentifiers)
        dataSource.apply(snapshot, animatingDifferences: false)
    }

    private var hasAnythingToClear: Bool { (model.report?.total ?? 0) > 0 }

    /// A size's sample while the cache is measured: the row is drawn
    /// redacted until then (#1769), never "Measuring…".
    private static let sampleSize = "000.0 MB"

    private static func redactedUntilMeasured(
        _ content: UIListContentConfiguration, report: StorageReport?
    ) -> any UIContentConfiguration {
        report == nil ? SkeletonRowConfiguration(redacting: content) : content
    }

    private func configure(_ cell: UICollectionViewListCell, for item: Item) {
        cell.accessories = []
        cell.accessibilityTraits.remove(.selected)
        cell.accessibilityHint = nil
        let report = model.report
        switch item {
        case .category(let category):
            var content = Self.label(Self.title(category), symbol: Self.symbol(category))
            content.secondaryText = report.map { MediaCacheInventory.formatted($0.bytes(in: category)) } ?? Self.sampleSize
            cell.contentConfiguration = Self.redactedUntilMeasured(content, report: report)
            cell.accessibilityHint = (report?.bytes(in: category) ?? 0) > 0 ? "Clears \(Self.title(category).lowercased())" : nil
        case .total:
            var content = UIListContentConfiguration.valueCell()
            content.text = "Total"
            content.textProperties.font = .appFont(forTextStyle: .headline)
            content.secondaryText = report.map { MediaCacheInventory.formatted($0.total) } ?? Self.sampleSize
            cell.contentConfiguration = Self.redactedUntilMeasured(content, report: report)
        case .clearAll:
            var content = UIListContentConfiguration.cell()
            content.text = "Clear All"
            content.textProperties.color = hasAnythingToClear ? .systemRed : .secondaryLabel
            cell.contentConfiguration = content
        case .inUse:
            var content = Self.label("In Use", symbol: "internaldrive")
            content.secondaryText = report.map {
                "\(MediaCacheInventory.formatted($0.limitedDiskBytes)) of \(MediaCacheInventory.formatted(model.limitBytes))"
            } ?? Self.sampleSize
            cell.contentConfiguration = Self.redactedUntilMeasured(content, report: report)
        case .limit(let limit):
            var content = UIListContentConfiguration.cell()
            content.text = Self.title(limit)
            cell.contentConfiguration = content
            if model.limit == limit {
                cell.accessories = [.checkmark()]
                cell.accessibilityTraits.insert(.selected)
            }
        case .lessCellularData:
            cell.contentConfiguration = Self.label("Use Less Cellular Data", symbol: "antenna.radiowaves.left.and.right")
            let toggle = UISwitch()
            toggle.isOn = model.usesLessCellularData
            toggle.addAction(UIAction { [weak self] action in
                guard let toggle = action.sender as? UISwitch else { return }
                self?.model.setUsesLessCellularData(toggle.isOn)
            }, for: .valueChanged)
            cell.accessories = [.customView(configuration: .init(customView: toggle, placement: .trailing(displayed: .always)))]
        }
    }

    private static func label(_ text: String, symbol: String) -> UIListContentConfiguration {
        var content = UIListContentConfiguration.valueCell()
        content.text = text
        content.image = UIImage(systemName: symbol)
        content.imageProperties.tintColor = .label
        return content
    }

    // MARK: - Actions

    private func confirmClear(_ category: CacheCategory?) {
        let what = category.map { Self.title($0).lowercased() }
        let sheet = UIAlertController(
            title: what.map { "Clear \($0)?" } ?? "Clear all cached data?",
            message: (what.map { "\($0.prefix(1).uppercased() + $0.dropFirst()) are" } ?? "Images, videos, sounds, messages and pages are")
                + " downloaded again when you next see them. Drafts, posts and your settings aren't affected.",
            preferredStyle: .actionSheet
        )
        sheet.addAction(UIAlertAction(title: category.map { "Clear \(Self.title($0))" } ?? "Clear All", style: .destructive) { [weak self] _ in
            guard let model = self?.model else { return }
            Task { await model.clear(category) }
        })
        sheet.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        if let popover = sheet.popoverPresentationController {
            popover.sourceView = view
            popover.sourceRect = CGRect(x: view.bounds.midX, y: view.bounds.maxY - 60, width: 0, height: 0)
            popover.permittedArrowDirections = []
        }
        present(sheet, animated: true)
    }

    private func choose(_ limit: CacheStorageLimit) {
        guard limit != model.limit else { return }
        Haptics.play(.tick)
        Task { await model.choose(limit) }
    }
}

extension StorageSettingsViewController: UICollectionViewDelegate {
    func collectionView(_ collectionView: UICollectionView, shouldHighlightItemAt indexPath: IndexPath) -> Bool {
        switch dataSource.itemIdentifier(for: indexPath) {
        case .category(let category): (model.report?.bytes(in: category) ?? 0) > 0
        case .clearAll: hasAnythingToClear
        case .limit: true
        default: false
        }
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        switch dataSource.itemIdentifier(for: indexPath) {
        case .category(let category): confirmClear(category)
        case .clearAll: confirmClear(nil)
        case .limit(let limit): choose(limit)
        default: break
        }
    }
}

// MARK: - How it is left (#1144)

extension StorageSettingsViewController: StackScreen {
    var leaving: ScreenLeaving { .nativeBack }
}
