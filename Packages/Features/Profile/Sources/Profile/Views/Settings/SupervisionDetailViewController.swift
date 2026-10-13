import CoreModels
import CoreNavigation
import CoreNetworking
import DesignSystem
import MediaCore
import UIKit

/// Settings → Family and Teens → a supervision (#417): who the other side is,
/// since when, and End Supervision. Either side may end it (backend #670);
/// the other side is told (#848), and the confirmation says so.
final class SupervisionDetailViewController: UIViewController {
    enum Section: Hashable {
        case profiles, about, end
    }

    enum Item: Hashable {
        case profile(SupervisionProfile)
        case role
        case since
        case end
    }

    let supervision: Supervision
    private let list: SupervisionListModel
    private let imagePipeline: ImagePipeline?
    private let router: (any Router)?
    /// The supervision ended, or was found already gone (true): the opener
    /// steps back and says which.
    private let onEnded: (SupervisionDetailViewController, Supervision, Bool) -> Void
    private var collectionView: UICollectionView!
    private(set) var dataSource: UICollectionViewDiffableDataSource<Section, Item>!
    private let avatarLoads = RowAvatarLoads()
    private(set) var isEnding = false
    /// Confirms the end; a test hands in its own (an action sheet never
    /// finishes presenting in the test host).
    var confirmEnd: ((@escaping () -> Void) -> Void)?

    init(
        supervision: Supervision,
        list: SupervisionListModel,
        imagePipeline: ImagePipeline?,
        router: (any Router)?,
        onEnded: @escaping (SupervisionDetailViewController, Supervision, Bool) -> Void
    ) {
        self.supervision = supervision
        self.list = list
        self.imagePipeline = imagePipeline
        self.router = router
        self.onEnded = onEnded
        super.init(nibName: nil, bundle: nil)
        title = supervision.name
        hidesBottomBarWhenPushed = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidLoad() {
        super.viewDidLoad()
        navigationItem.largeTitleDisplayMode = .never
        var config = UICollectionLayoutListConfiguration(appearance: .insetGrouped)
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
    }

    static func footer(_ section: Section, supervision: Supervision) -> String? {
        switch section {
        case .profiles:
            supervision.otherRole == .teen
                ? "The teen's profiles. They see that you supervise them."
                : "This person can see your daily time in the app and set limits on your account."
        case .about: nil
        case .end:
            supervision.otherRole == .supervisor
                ? "\(supervision.handleText) is told when you end it. Supervision also ends by itself when you turn 18."
                : "\(supervision.handleText) is told when you end it. It also ends by itself when they turn 18."
        }
    }

    private func configureDataSource() {
        let person = UICollectionView.CellRegistration<PersonListCell, SupervisionProfile> { [weak self] cell, _, profile in
            cell.configure(with: PersonRowContent(
                displayName: profile.name,
                handle: "@\(profile.handle)",
                monogram: MonogramAvatarView.monogram(name: profile.displayName, handle: profile.handle)
            ))
            cell.setAvatarImage(nil)
            if self?.router != nil { cell.accessories.append(.disclosureIndicator()) }
            self?.avatarLoads.load(profile.avatarURL, using: self?.imagePipeline, for: cell) { [weak cell] image in
                cell?.setAvatarImage(image)
            }
        }
        let row = UICollectionView.CellRegistration<UICollectionViewListCell, Item> { [weak self] cell, _, item in
            guard let self else { return }
            var content = UIListContentConfiguration.valueCell()
            switch item {
            case .role:
                content.text = "Role"
                content.secondaryText = SupervisionCopy.roleText(supervision)
            case .since:
                content.text = "Linked"
                content.secondaryText = SupervisionCopy.sinceText(supervision.since)
            case .end:
                content = .cell()
                content.text = SupervisionCopy.endAction
                content.textProperties.color = isEnding ? .secondaryLabel : .systemRed
                content.textProperties.alignment = .center
                cell.accessibilityTraits.insert(.button)
            case .profile:
                break
            }
            cell.contentConfiguration = content
        }
        dataSource = UICollectionViewDiffableDataSource<Section, Item>(collectionView: collectionView) { collectionView, indexPath, item in
            if case .profile(let profile) = item {
                return collectionView.dequeueConfiguredReusableCell(using: person, for: indexPath, item: profile)
            }
            return collectionView.dequeueConfiguredReusableCell(using: row, for: indexPath, item: item)
        }
        let footer = UICollectionView.SupplementaryRegistration<UICollectionViewListCell>(
            elementKind: UICollectionView.elementKindSectionFooter
        ) { [weak self] view, _, indexPath in
            guard let self else { return }
            var content = UIListContentConfiguration.footer()
            content.text = dataSource.sectionIdentifier(for: indexPath.section).flatMap {
                Self.footer($0, supervision: self.supervision)
            }
            view.contentConfiguration = content
        }
        dataSource.supplementaryViewProvider = { collectionView, _, indexPath in
            collectionView.dequeueConfiguredReusableSupplementary(using: footer, for: indexPath)
        }
    }

    private func applySnapshot() {
        var snapshot = NSDiffableDataSourceSnapshot<Section, Item>()
        if !supervision.profiles.isEmpty {
            snapshot.appendSections([.profiles])
            snapshot.appendItems(supervision.profiles.map(Item.profile), toSection: .profiles)
        }
        snapshot.appendSections([.about, .end])
        snapshot.appendItems([.role, .since], toSection: .about)
        snapshot.appendItems([.end], toSection: .end)
        snapshot.reconfigureItems(snapshot.itemIdentifiers)
        dataSource.apply(snapshot, animatingDifferences: false)
    }

    // MARK: End

    private func askToEnd() {
        guard !isEnding else { return }
        let end: () -> Void = { [weak self] in self?.end() }
        if let confirmEnd { return confirmEnd(end) }
        let sheet = UIAlertController(
            title: SupervisionCopy.endTitle(supervision),
            message: SupervisionCopy.endMessage(supervision),
            preferredStyle: .actionSheet
        )
        sheet.addAction(UIAlertAction(title: SupervisionCopy.endAction, style: .destructive) { _ in end() })
        sheet.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        if let popover = sheet.popoverPresentationController {
            popover.sourceView = view
            popover.sourceRect = CGRect(x: view.bounds.midX, y: view.bounds.maxY - 60, width: 0, height: 0)
            popover.permittedArrowDirections = []
        }
        present(sheet, animated: true)
    }

    /// Ends it once the server agrees; a refusal keeps the screen as it was.
    func end() {
        guard !isEnding else { return }
        isEnding = true
        applySnapshot()
        Task { [weak self] in
            guard let self else { return }
            do {
                try await list.end(supervision)
                onEnded(self, supervision, false)
            } catch SupervisionError.notFound {
                // Already gone (the other side ended it, or the teen turned
                // 18): the list has dropped it; the opener says so.
                onEnded(self, supervision, true)
            } catch {
                isEnding = false
                applySnapshot()
                Feedback.failure(
                    SupervisionCopy.failureText(error, teen: supervision.otherRole == .supervisor, fallback: "Couldn't end supervision"),
                    from: self
                )
            }
        }
    }
}

extension SupervisionDetailViewController: UICollectionViewDelegate {
    func collectionView(_ collectionView: UICollectionView, shouldHighlightItemAt indexPath: IndexPath) -> Bool {
        switch dataSource.itemIdentifier(for: indexPath) {
        case .profile: router != nil
        case .end: !isEnding
        default: false
        }
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        switch dataSource.itemIdentifier(for: indexPath) {
        case .profile(let profile):
            router?.route(to: .profile(ProfileID(profile.profileID), stub: nil))
        case .end:
            askToEnd()
        default:
            break
        }
    }
}
