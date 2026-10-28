import CoreNetworking
import DesignSystem
import UIKit

/// Settings → Privacy → Location Sharing (#398): ghost mode and city-level
/// precision, enforced by the server on the map and on posts for everyone
/// but the author (backend #717, #718). Not optimistic: a change shows where
/// the tap put it, with the loader beside it, until the server holds it
/// (#1775, `SettingSaves`).
final class LocationSharingViewController: UIViewController {
    enum Phase: Equatable {
        case loading
        case loaded(LocationSharingSettings)
        case failed
    }

    enum Section: Hashable {
        case ghost, precision, comingSoon
    }

    private enum Item: Hashable {
        case ghost
        case precise, city
        case planned(String)
        case loading
        case failed
        /// Past 10 s (#1770): a row a tap retries.
        case takingLonger
    }

    static let planned = ["Who can see your location", "Add your location to new posts by default"]

    private let manager: any LocationSharingManaging
    private var phase: Phase = .loading {
        didSet {
            // Every answer, a save's included, is the next visit's first
            // frame (#1776).
            if case .loaded(let value) = phase { settingsCache?.store(value, as: LocationSharingRecord.self, viewer: settingsWriter) }
            applySnapshot()
        }
    }
    /// The screen's last answer on the device (#1776): it opens on it, with
    /// no skeleton, then revalidates in place. Set by the builder.
    var settingsCache: SettingsLocalCache?
    /// The viewer the screen opened for: what its answers are stored as.
    private lazy var settingsWriter = settingsCache?.viewer
    /// Why the last load failed, kept beside `.failed` so the failed row
    /// can say "You’re offline" when that is the cause (#794). Set before
    /// the phase, so the redraw `.failed` triggers already reads it.
    private var loadFailure: NetworkFailure?
    /// The two settings a row saves.
    private enum Setting: Hashable, Sendable {
        case ghost, cityLevel
    }

    /// The settings on their way to the server (#1775).
    private lazy var saves: SettingSaves<Setting, Bool> = {
        let saves = SettingSaves<Setting, Bool>()
        saves.onChange = { [weak self] in self?.applySnapshot() }
        return saves
    }()
    private var collectionView: UICollectionView!
    private var dataSource: UICollectionViewDiffableDataSource<Section, Item>!

    init(manager: any LocationSharingManaging) {
        self.manager = manager
        super.init(nibName: nil, bundle: nil)
        title = "Location Sharing"
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
        // ⚠️ CACHE FIRST (#1776, the rule of #1756): what the server last said
        // is the first frame; the read below revalidates it in place.
        if case .loaded = phase {
        } else if let stored = settingsCache?.value(LocationSharingRecord.self) {
            phase = .loaded(stored)
        } else {
            phase = .loading
        }
        Task { [weak self] in
            guard let self else { return }
            do {
                phase = .loaded(try await manager.locationSharing())
            } catch {
                loadFailure = NetworkFailure.of(error)
                // A failed revalidation keeps the answer on screen.
                if case .loaded = phase { return }
                phase = .failed
            }
        }
    }

    // MARK: - Copy

    static func header(_ section: Section) -> String? {
        switch section {
        case .ghost: nil
        case .precision: "When Others See Your Location"
        case .comingSoon: "Coming Soon"
        }
    }

    static func footer(_ section: Section) -> String {
        switch section {
        case .ghost:
            "When it's on, your posts leave everyone else's map and don't show where they were posted. You still see your own places. Applies to this profile."
        case .precision:
            "City Level shows only the city: on the map your posts appear only when zoomed out to the region, and never at the exact spot."
        case .comingSoon:
            "These need a server update and aren't available yet."
        }
    }

    // MARK: - List

    private func configureDataSource() {
        let registration = UICollectionView.CellRegistration<UICollectionViewListCell, Item> { [weak self] cell, _, item in
            guard let self else { return }
            cell.accessories = []
            var content = UIListContentConfiguration.subtitleCell()
            content.secondaryTextProperties.color = .secondaryLabel
            let settings: LocationSharingSettings? = if case .loaded(let current) = phase { current } else { nil }
            switch item {
            case .ghost:
                content = .cell()
                content.text = "Ghost Mode"
                content.image = UIImage(systemName: "eye.slash")
                content.imageProperties.tintColor = .label
                let toggle = UISwitch()
                toggle.isOn = shown(.ghost, in: settings)
                toggle.isEnabled = !saves.isSaving(.ghost)
                toggle.addAction(UIAction { [weak self] action in
                    guard let toggle = action.sender as? UISwitch else { return }
                    self?.set(.ghost, to: toggle.isOn)
                }, for: .valueChanged)
                let control = UICellAccessory.customView(configuration: .init(customView: toggle, placement: .trailing(displayed: .always)))
                cell.accessories = saves.isSaving(.ghost) ? [.busy(), control] : [control]
            case .precise, .city:
                let isCity = item == .city
                content.text = isCity ? "City Level" : "Precise"
                content.secondaryText = isCity ? "Others see the city you posted from." : "Others see where you posted."
                let ghosted = shown(.ghost, in: settings)
                content.textProperties.color = ghosted ? .secondaryLabel : .label
                if settings != nil, shown(.cityLevel, in: settings) == isCity {
                    cell.accessories = saves.isSaving(.cityLevel) ? [.busy(), .checkmark()] : [.checkmark()]
                }
            case .planned(let title):
                content = .cell()
                content.text = title
                content.textProperties.color = .secondaryLabel
            case .loading:
                cell.contentConfiguration = SkeletonRowConfiguration(sample: "A row of this list")
                cell.accessories = []
                return
            case .takingLonger:
                content = .cell()
                content.text = TakingLongerCopy.row
                content.textProperties.color = .secondaryLabel
            case .failed:
                content = .cell()
                // "You’re offline…" when that is why (#794).
                content.text = FailureCopy.row(
                    for: loadFailure, fallback: "Couldn't load your location settings. Tap to try again."
                )
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
        guard dataSource != nil else { return }
        var snapshot = NSDiffableDataSourceSnapshot<Section, Item>()
        switch phase {
        case .loading:
            snapshot.appendSections([.ghost])
            // The kit's timing (#1770): nothing for its delay, the bones,
            // "taking longer" past 10 s.
            switch loadingGate.loading() {
            case .bones: snapshot.appendItems([.loading], toSection: .ghost)
            case .takingLonger: snapshot.appendItems([.takingLonger], toSection: .ghost)
            case .nothing: break
            }
        case .failed:
            snapshot.appendSections([.ghost])
            snapshot.appendItems([.failed], toSection: .ghost)
        case .loaded:
            snapshot.appendSections([.ghost, .precision, .comingSoon])
            snapshot.appendItems([.ghost], toSection: .ghost)
            snapshot.appendItems([.precise, .city], toSection: .precision)
            snapshot.appendItems(Self.planned.map(Item.planned), toSection: .comingSoon)
            snapshot.reconfigureItems([.ghost, .precise, .city])
        }
        let animated = false
        if case .loading = phase {
            dataSource.apply(snapshot, animatingDifferences: animated)
        } else {
            // The answer waits out the bones' minimum (#1770).
            loadingGate.landed { [weak self] in self?.dataSource.apply(snapshot, animatingDifferences: animated) }
        }
    }

    /// The settings' loading on the kit's timing (#1770). Injectable so a
    /// test steps it.
    var skeletonClock: LoadingClock = .system
    private lazy var loadingGate: ListSkeletonGate = {
        let gate = ListSkeletonGate(clock: skeletonClock)
        gate.onChange = { [weak self] in self?.applySnapshot() }
        return gate
    }()

    /// What a row shows for `setting`: the change on its way, else the
    /// server's.
    private func shown(_ setting: Setting, in settings: LocationSharingSettings?) -> Bool {
        if let pending = saves.value(for: setting) { return pending }
        switch setting {
        case .ghost: return settings?.ghost ?? false
        case .cityLevel: return settings?.cityLevel ?? false
        }
    }

    /// Saves one setting over the record the saves before it left — the
    /// server takes the whole record.
    private func set(_ setting: Setting, to value: Bool) {
        guard case .loaded(let current) = phase, shown(setting, in: current) != value else { return }
        saves.save(value, for: setting, { [weak self] value in
            guard let self, case .loaded(var next) = phase else { return }
            switch setting {
            case .ghost: next.ghost = value
            case .cityLevel: next.cityLevel = value
            }
            try await manager.setLocationSharing(next)
            phase = .loaded(next)
        }, failed: { [weak self] _ in
            let alert = UIAlertController(title: nil, message: "Couldn't change your location sharing. Try again.", preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "OK", style: .default))
            self?.present(alert, animated: true)
        })
    }
}

extension LocationSharingViewController: UICollectionViewDelegate {
    func collectionView(_ collectionView: UICollectionView, shouldHighlightItemAt indexPath: IndexPath) -> Bool {
        switch dataSource.itemIdentifier(for: indexPath) {
        case .precise, .city, .failed: true
        default: false
        }
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        switch dataSource.itemIdentifier(for: indexPath) {
        case .precise: set(.cityLevel, to: false)
        case .city: set(.cityLevel, to: true)
        case .failed: load()
        case .takingLonger:
            loadingGate.retry()
            load()
        default: break
        }
    }
}

#if DEBUG
extension LocationSharingViewController {
    /// Internal for tests: the settings on screen, nil while none are.
    var debugShownSettings: LocationSharingSettings? {
        if case .loaded(let settings) = phase { settings } else { nil }
    }
}
#endif
