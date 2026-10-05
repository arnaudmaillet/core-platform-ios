import DesignSystem
import UIKit

/// Settings → Privacy → Location Sharing (#398): ghost mode and city-level
/// precision, enforced by the server on the map and on posts for everyone
/// but the author (backend #717, #718). Not optimistic.
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
    }

    static let planned = ["Who can see your location", "Add your location to new posts by default"]

    private let manager: any LocationSharingManaging
    private var phase: Phase = .loading {
        didSet { applySnapshot() }
    }
    private var isSaving = false
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
        phase = .loading
        Task { [weak self] in
            guard let self else { return }
            do {
                phase = .loaded(try await manager.locationSharing())
            } catch {
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
                toggle.isOn = settings?.ghost ?? false
                toggle.isEnabled = !isSaving
                toggle.addAction(UIAction { [weak self] action in
                    guard let toggle = action.sender as? UISwitch else { return }
                    self?.save { $0.ghost = toggle.isOn }
                }, for: .valueChanged)
                cell.accessories = [.customView(configuration: .init(customView: toggle, placement: .trailing(displayed: .always)))]
            case .precise, .city:
                let isCity = item == .city
                content.text = isCity ? "City Level" : "Precise"
                content.secondaryText = isCity ? "Others see the city you posted from." : "Others see where you posted."
                let ghosted = settings?.ghost ?? false
                content.textProperties.color = ghosted ? .secondaryLabel : .label
                if settings?.cityLevel == isCity { cell.accessories = [.checkmark()] }
            case .planned(let title):
                content = .cell()
                content.text = title
                content.textProperties.color = .secondaryLabel
            case .loading:
                content = .cell()
                content.text = "Loading…"
                content.textProperties.color = .secondaryLabel
            case .failed:
                content = .cell()
                content.text = "Couldn't load your location settings. Tap to try again."
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
            snapshot.appendItems([.loading], toSection: .ghost)
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
        dataSource.apply(snapshot, animatingDifferences: false)
    }

    private func save(_ change: (inout LocationSharingSettings) -> Void) {
        guard case .loaded(let current) = phase, !isSaving else { return }
        var next = current
        change(&next)
        guard next != current else { return }
        isSaving = true
        applySnapshot()
        Task { [weak self] in
            guard let self else { return }
            do {
                try await manager.setLocationSharing(next)
                isSaving = false
                phase = .loaded(next)
            } catch {
                isSaving = false
                applySnapshot()
                let alert = UIAlertController(title: nil, message: "Couldn't change your location sharing. Try again.", preferredStyle: .alert)
                alert.addAction(UIAlertAction(title: "OK", style: .default))
                present(alert, animated: true)
            }
        }
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
        case .precise: save { $0.cityLevel = false }
        case .city: save { $0.cityLevel = true }
        case .failed: load()
        default: break
        }
    }
}
