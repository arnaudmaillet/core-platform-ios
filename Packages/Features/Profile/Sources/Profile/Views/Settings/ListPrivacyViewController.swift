import CoreNetworking
import DesignSystem
import UIKit

/// Settings → Privacy → Followers and Following Lists (#403): who else may
/// see each list, enforced by the server (`social_graph.v1` list privacy,
/// backend #720), so a hidden list is hidden in everyone's app.
///
/// Not optimistic, like Private Account: the checkmark moves once the server
/// holds the new audience, because a privacy setting that shows "Only Me"
/// while the list is still public is the one kind of wrong this screen can't
/// afford.
final class ListPrivacyViewController: UIViewController {
    enum Phase: Equatable {
        case loading
        case loaded(ListPrivacy)
        case failed
    }

    enum Section: Hashable {
        case followers, following
    }

    private enum Item: Hashable {
        case audience(Section, ListAudience)
        case loading
        case failed
    }

    private let manager: any ListPrivacyManaging
    private var phase: Phase = .loading {
        didSet { applySnapshot() }
    }
    /// Why the last load failed, kept beside `.failed` so the failed row
    /// can say "You’re offline" when that is the cause (#794). Set before
    /// the phase, so the redraw `.failed` triggers already reads it.
    private var loadFailure: NetworkFailure?
    private var isSaving = false
    private var collectionView: UICollectionView!
    private var dataSource: UICollectionViewDiffableDataSource<Section, Item>!

    init(manager: any ListPrivacyManaging) {
        self.manager = manager
        super.init(nibName: nil, bundle: nil)
        title = "Followers and Following"
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
                phase = .loaded(try await manager.listPrivacy())
            } catch {
                loadFailure = NetworkFailure.of(error)
                phase = .failed
            }
        }
    }

    static func header(_ section: Section) -> String {
        switch section {
        case .followers: "Who Can See Your Followers"
        case .following: "Who Can See Who You Follow"
        }
    }

    static let footer = "Applies to this profile only, in everyone's app. Your Friends list is made from these two lists, so it follows the stricter one. You always see your own lists."

    private func configureDataSource() {
        let registration = UICollectionView.CellRegistration<UICollectionViewListCell, Item> { [weak self] cell, _, item in
            guard let self else { return }
            cell.accessories = []
            switch item {
            case .audience(let section, let audience):
                var content = UIListContentConfiguration.subtitleCell()
                content.text = audience.title
                content.secondaryText = audience.detail
                content.secondaryTextProperties.color = .secondaryLabel
                cell.contentConfiguration = content
                if case .loaded(let privacy) = phase, Self.audience(in: privacy, for: section) == audience {
                    cell.accessories = [.checkmark()]
                    cell.accessibilityTraits.insert(.selected)
                } else {
                    cell.accessibilityTraits.remove(.selected)
                }
            case .loading:
                var content = UIListContentConfiguration.cell()
                content.text = "Loading…"
                content.textProperties.color = .secondaryLabel
                cell.contentConfiguration = content
            case .failed:
                var content = UIListContentConfiguration.cell()
                // "You’re offline…" when that is why (#794).
                content.text = FailureCopy.row(
                    for: loadFailure, fallback: "Couldn't load your list privacy. Tap to try again."
                )
                content.textProperties.color = .secondaryLabel
                cell.contentConfiguration = content
            }
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
            content.text = self?.dataSource.sectionIdentifier(for: indexPath.section) == .following ? Self.footer : nil
            view.contentConfiguration = content
        }
        dataSource.supplementaryViewProvider = { collectionView, kind, indexPath in
            kind == UICollectionView.elementKindSectionHeader
                ? collectionView.dequeueConfiguredReusableSupplementary(using: header, for: indexPath)
                : collectionView.dequeueConfiguredReusableSupplementary(using: footer, for: indexPath)
        }
    }

    private static func audience(in privacy: ListPrivacy, for section: Section) -> ListAudience {
        section == .followers ? privacy.followers : privacy.following
    }

    private func applySnapshot() {
        guard dataSource != nil else { return }
        var snapshot = NSDiffableDataSourceSnapshot<Section, Item>()
        snapshot.appendSections([.followers, .following])
        switch phase {
        case .loading:
            snapshot.appendItems([.loading], toSection: .followers)
        case .failed:
            snapshot.appendItems([.failed], toSection: .followers)
        case .loaded:
            for section in [Section.followers, .following] {
                snapshot.appendItems(ListAudience.allCases.map { .audience(section, $0) }, toSection: section)
            }
        }
        snapshot.reconfigureItems(snapshot.itemIdentifiers)
        dataSource.apply(snapshot, animatingDifferences: false)
    }

    private func choose(_ audience: ListAudience, for section: Section) {
        guard case .loaded(let current) = phase, !isSaving,
              Self.audience(in: current, for: section) != audience else { return }
        isSaving = true
        Task { [weak self] in
            guard let self else { return }
            do {
                let saved = try await manager.setListPrivacy(
                    followers: section == .followers ? audience : nil,
                    following: section == .following ? audience : nil
                )
                phase = .loaded(saved)
                HapticSelection().selectionChanged()
            } catch {
                let alert = UIAlertController(title: nil, message: "Couldn't change who can see this list. Try again.", preferredStyle: .alert)
                alert.addAction(UIAlertAction(title: "OK", style: .default))
                present(alert, animated: true)
            }
            isSaving = false
        }
    }
}

extension ListPrivacyViewController: UICollectionViewDelegate {
    func collectionView(_ collectionView: UICollectionView, shouldHighlightItemAt indexPath: IndexPath) -> Bool {
        switch dataSource.itemIdentifier(for: indexPath) {
        case .audience, .failed: true
        default: false
        }
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        switch dataSource.itemIdentifier(for: indexPath) {
        case .audience(let section, let audience): choose(audience, for: section)
        case .failed: load()
        default: break
        }
    }
}
