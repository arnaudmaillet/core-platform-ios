import CoreStorage
import DesignSystem
import UIKit

/// Who can see the viewer's relationship lists.
///
/// ## ⚠️ What this screen can and cannot do
///
/// The toggles are **stored on this device and honoured by this client**.
/// They are not enforced by the backend, because the backend has no way to
/// express them: `profile.v1` carries one whole-profile `SetVisibility` and no
/// per-list field at all (`dev/BACKEND_GAPS.md` §13a). Another person's copy of
/// the app asks the fleet, and the fleet has never heard of these flags.
///
/// That is why the footer says so in plain words instead of the usual
/// reassuring settings copy. A privacy screen that overstates its reach is
/// worse than no privacy screen — it converts a known gap into a false belief.
/// When the per-list fields land, this screen keeps its shape and the store
/// gains a sync path.
///
/// An inset-grouped list, not the app's compact separator-less person rows:
/// this is Settings, and the platform's own privacy screens are what a viewer
/// is pattern-matching against here.
final class PrivacySettingsViewController: UIViewController {
    private enum Section: Int, CaseIterable {
        case lists
    }

    /// One row per list. Raw values are the persisted keys' peers — the order
    /// here is the order on screen.
    private enum Row: Int, CaseIterable {
        case followers, following, friends

        var title: String {
            switch self {
            case .followers: "Hide Followers"
            case .following: "Hide Following"
            case .friends: "Hide Friends"
            }
        }

        var subtitle: String {
            switch self {
            case .followers: "Only you can see who follows you."
            case .following: "Only you can see who you follow."
            // Friends is derived from the other two, so it can be hidden on
            // its own but is also implied by hiding either side — said here
            // rather than enforced, since the viewer may want exactly one.
            case .friends: "Only you can see your mutual follows."
            }
        }
    }

    private let store: RelationshipPrivacyStore
    private var settings: RelationshipPrivacySettings
    private var collectionView: UICollectionView!
    private var dataSource: UICollectionViewDiffableDataSource<Section, Row>!

    init(store: RelationshipPrivacyStore) {
        self.store = store
        self.settings = store.settings
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Privacy"
        navigationItem.largeTitleDisplayMode = .never
        view.backgroundColor = .systemGroupedBackground
        configureCollectionView()
        applySnapshot()
    }

    private func configureCollectionView() {
        var configuration = UICollectionLayoutListConfiguration(appearance: .insetGrouped)
        configuration.footerMode = .supplementary
        let layout = UICollectionViewCompositionalLayout.list(using: configuration)

        collectionView = UICollectionView(frame: view.bounds, collectionViewLayout: layout)
        collectionView.pin(to: view)

        let cellRegistration = UICollectionView.CellRegistration<
            UICollectionViewListCell, Row
        > { [weak self] cell, _, row in
            guard let self else { return }
            var content = UIListContentConfiguration.subtitleCell()
            content.text = row.title
            content.secondaryText = row.subtitle
            content.secondaryTextProperties.color = .secondaryLabel
            cell.contentConfiguration = content

            // A `UISwitch` in a cell accessory, so the whole row is not
            // selectable — the switch is the only control, and a row-wide tap
            // target that toggles nothing reads as broken.
            let toggle = UISwitch()
            toggle.isOn = self.isOn(row)
            toggle.addAction(
                UIAction { [weak self] action in
                    guard let toggle = action.sender as? UISwitch else { return }
                    self?.setOn(toggle.isOn, for: row)
                },
                for: .valueChanged
            )
            cell.accessories = [.customView(configuration: .init(
                customView: toggle, placement: .trailing(displayed: .always)
            ))]
        }

        let footerRegistration = UICollectionView.SupplementaryRegistration<
            UICollectionViewListCell
        >(elementKind: UICollectionView.elementKindSectionFooter) { footer, _, _ in
            var content = UIListContentConfiguration.groupedFooter()
            content.text = """
                These preferences apply on this device. Hiding a list here \
                doesn't yet remove it from other people's apps — that needs a \
                server-side setting we don't have yet.
                """
            content.textProperties.numberOfLines = 0
            footer.contentConfiguration = content
        }

        dataSource = UICollectionViewDiffableDataSource<Section, Row>(
            collectionView: collectionView
        ) { collectionView, indexPath, row in
            collectionView.dequeueConfiguredReusableCell(
                using: cellRegistration, for: indexPath, item: row
            )
        }
        dataSource.supplementaryViewProvider = { collectionView, _, indexPath in
            collectionView.dequeueConfiguredReusableSupplementary(
                using: footerRegistration, for: indexPath
            )
        }
    }

    private func applySnapshot() {
        var snapshot = NSDiffableDataSourceSnapshot<Section, Row>()
        snapshot.appendSections([.lists])
        snapshot.appendItems(Row.allCases, toSection: .lists)
        dataSource.apply(snapshot, animatingDifferences: false)
    }

    private func isOn(_ row: Row) -> Bool {
        switch row {
        case .followers: settings.hidesFollowers
        case .following: settings.hidesFollowing
        case .friends: settings.hidesFriends
        }
    }

    /// Written through immediately rather than on a Save button: these are
    /// switches, and a switch that needs confirming is one the viewer will
    /// assume already took effect.
    private func setOn(_ isOn: Bool, for row: Row) {
        store.update { settings in
            switch row {
            case .followers: settings.hidesFollowers = isOn
            case .following: settings.hidesFollowing = isOn
            case .friends: settings.hidesFriends = isOn
            }
        }
        settings = store.settings
    }
}
