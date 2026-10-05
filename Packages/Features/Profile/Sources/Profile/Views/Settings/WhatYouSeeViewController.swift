import DesignSystem
import UIKit

/// Settings → What You See (#407): how much sensitive content the feeds may
/// show (synced on the profile, backend #731), and how each feed is ordered —
/// the plain-language account of the recommender DSA Art. 27 asks for.
///
/// Not optimistic, like the other privacy-adjacent choices: the checkmark
/// moves once the server holds it.
final class WhatYouSeeViewController: UIViewController {
    enum Phase: Equatable {
        case loading
        case loaded(SensitiveContentLevel)
        case failed
    }

    enum Section: Hashable {
        case sensitive, ordering
    }

    private enum Item: Hashable {
        case level(SensitiveContentLevel)
        case loading
        case failed
        case following
        case forYou
    }

    private let preferences: any FeedPreferencesManaging
    /// Under 18: Standard isn't offered (the server clamps it anyway).
    private let isTeen: () async -> Bool
    private var teen = false
    private var phase: Phase = .loading {
        didSet { applySnapshot() }
    }
    private var isSaving = false
    private var collectionView: UICollectionView!
    private var dataSource: UICollectionViewDiffableDataSource<Section, Item>!

    init(preferences: any FeedPreferencesManaging, isTeen: @escaping () async -> Bool = { false }) {
        self.preferences = preferences
        self.isTeen = isTeen
        super.init(nibName: nil, bundle: nil)
        title = SettingsSection.whatYouSee.title
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
            teen = await isTeen()
            do {
                phase = .loaded(try await preferences.sensitiveContent())
            } catch {
                phase = .failed
            }
        }
    }

    // MARK: - Copy

    static func header(_ section: Section) -> String {
        switch section {
        case .sensitive: "Sensitive Content"
        case .ordering: "How Your Feeds Are Ordered"
        }
    }

    static func footer(_ section: Section, teen: Bool) -> String {
        switch section {
        case .sensitive:
            teen
                ? "You're under 18, so posts marked as sensitive stay out of your feeds. Applies to this profile."
                : "Applies to this profile, on all your devices."
        case .ordering:
            "Neither feed uses a profile of your interests, so there's nothing to reset. If personalised recommendations come, you'll be able to turn them off here."
        }
    }

    static let followingDetail = "Posts from accounts you follow, newest first."
    static let forYouDetail = "Popular and recent posts, ranked the same way for everyone."

    // MARK: - List

    private func configureDataSource() {
        let registration = UICollectionView.CellRegistration<UICollectionViewListCell, Item> { [weak self] cell, _, item in
            guard let self else { return }
            cell.accessories = []
            var content = UIListContentConfiguration.subtitleCell()
            content.secondaryTextProperties.color = .secondaryLabel
            switch item {
            case .level(let level):
                content.text = level.title
                content.secondaryText = level.detail
                let unavailable = level == .standard && teen
                content.textProperties.color = unavailable ? .secondaryLabel : .label
                if case .loaded(let current) = phase, current == level {
                    cell.accessories = [.checkmark()]
                    cell.accessibilityTraits.insert(.selected)
                } else {
                    cell.accessibilityTraits.remove(.selected)
                }
                if unavailable { cell.accessibilityTraits.insert(.notEnabled) } else { cell.accessibilityTraits.remove(.notEnabled) }
            case .loading:
                content = .cell()
                content.text = "Loading…"
                content.textProperties.color = .secondaryLabel
            case .failed:
                content = .cell()
                content.text = "Couldn't load this setting. Tap to try again."
                content.textProperties.color = .secondaryLabel
            case .following:
                content.text = "Following"
                content.secondaryText = Self.followingDetail
                content.image = UIImage(systemName: "person.2")
                content.imageProperties.tintColor = .label
            case .forYou:
                content.text = "For You"
                content.secondaryText = Self.forYouDetail
                content.image = UIImage(systemName: "sparkles")
                content.imageProperties.tintColor = .label
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
            content.text = self?.dataSource.sectionIdentifier(for: indexPath.section).map(Self.header)
            view.contentConfiguration = content
        }
        let footer = UICollectionView.SupplementaryRegistration<UICollectionViewListCell>(
            elementKind: UICollectionView.elementKindSectionFooter
        ) { [weak self] view, _, indexPath in
            guard let self else { return }
            var content = UIListContentConfiguration.footer()
            content.text = dataSource.sectionIdentifier(for: indexPath.section).map { Self.footer($0, teen: self.teen) }
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
        snapshot.appendSections([.sensitive, .ordering])
        switch phase {
        case .loading: snapshot.appendItems([.loading], toSection: .sensitive)
        case .failed: snapshot.appendItems([.failed], toSection: .sensitive)
        case .loaded: snapshot.appendItems(SensitiveContentLevel.allCases.map(Item.level), toSection: .sensitive)
        }
        snapshot.appendItems([.following, .forYou], toSection: .ordering)
        snapshot.reconfigureItems(snapshot.itemIdentifiers)
        snapshot.reloadSections([.sensitive])
        dataSource.apply(snapshot, animatingDifferences: false)
    }

    private func choose(_ level: SensitiveContentLevel) {
        guard case .loaded(let current) = phase, current != level, !isSaving else { return }
        guard !(level == .standard && teen) else { return }
        isSaving = true
        Task { [weak self] in
            guard let self else { return }
            do {
                try await preferences.setSensitiveContent(level)
                phase = .loaded(level)
                HapticSelection().selectionChanged()
            } catch {
                let alert = UIAlertController(title: nil, message: "Couldn't change this setting. Try again.", preferredStyle: .alert)
                alert.addAction(UIAlertAction(title: "OK", style: .default))
                present(alert, animated: true)
            }
            isSaving = false
        }
    }
}

extension WhatYouSeeViewController: UICollectionViewDelegate {
    func collectionView(_ collectionView: UICollectionView, shouldHighlightItemAt indexPath: IndexPath) -> Bool {
        switch dataSource.itemIdentifier(for: indexPath) {
        case .level(let level): !(level == .standard && teen)
        case .failed: true
        default: false
        }
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        switch dataSource.itemIdentifier(for: indexPath) {
        case .level(let level): choose(level)
        case .failed: load()
        default: break
        }
    }
}
