import CoreNetworking
import DesignSystem
import MediaCore
import UIKit

/// Settings → Security and Login → Apps and Websites (#485, backend #667):
/// each app the holder let use their account — its icon, what it may do and
/// when it last did — and Remove Access, from a tap (with confirmation) or a
/// swipe. Withdrawing consent is as easy as giving it (GDPR Art. 7(3)).
final class AuthorizedAppsViewController: UIViewController {
    private enum Item: Hashable {
        case app(AuthorizedApp)
        case loading
        case failed
        case takingLonger
        case empty
    }

    private let viewModel: AuthorizedAppsViewModel
    private let imagePipeline: ImagePipeline?
    private var collectionView: UICollectionView!
    private var dataSource: UICollectionViewDiffableDataSource<Int, Item>!
    private var iconTasks: [ObjectIdentifier: Task<Void, Never>] = [:]

    init(viewModel: AuthorizedAppsViewModel, imagePipeline: ImagePipeline?) {
        self.viewModel = viewModel
        self.imagePipeline = imagePipeline
        super.init(nibName: nil, bundle: nil)
        title = Self.title
        hidesBottomBarWhenPushed = true
    }

    static let title = "Apps and Websites"

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidLoad() {
        super.viewDidLoad()
        navigationItem.largeTitleDisplayMode = .never
        configureCollectionView()
        configureDataSource()
        viewModel.onChange = { [weak self] in self?.applySnapshot() }
        applySnapshot()
        Task { await viewModel.load() }
    }

    private func configureCollectionView() {
        var config = UICollectionLayoutListConfiguration(appearance: .insetGrouped)
        config.footerMode = .supplementary
        config.trailingSwipeActionsConfigurationProvider = { [weak self] indexPath in
            guard let self, case .app(let app) = dataSource.itemIdentifier(for: indexPath) else { return nil }
            let action = UIContextualAction(style: .destructive, title: "Remove") { [weak self] _, _, done in
                self?.remove(app)
                done(true)
            }
            return UISwipeActionsConfiguration(actions: [action])
        }
        collectionView = UICollectionView(
            frame: view.bounds,
            collectionViewLayout: UICollectionViewCompositionalLayout.list(using: config)
        )
        collectionView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        collectionView.prefersSoftTopEdge()
        collectionView.delegate = self
        view.addSubview(collectionView)
    }

    private func configureDataSource() {
        let appRegistration = UICollectionView.CellRegistration<UICollectionViewListCell, AuthorizedApp> { [weak self] cell, _, app in
            var content = UIListContentConfiguration.subtitleCell()
            content.text = app.name
            content.secondaryText = Self.subtitle(for: app)
            content.secondaryTextProperties.color = .secondaryLabel
            content.secondaryTextProperties.numberOfLines = 2
            // The icon's place on the media ground while it loads (#1772);
            // the glyph for an app with no icon, or one that will not come.
            let awaitsIcon = app.iconURL != nil && self?.imagePipeline != nil
            content.image = awaitsIcon ? Surface.groundImage(size: CGSize(width: 36, height: 36)) : Self.iconGlyph
            content.imageProperties.tintColor = awaitsIcon ? Surface.mediaGround : .secondaryLabel
            content.imageProperties.maximumSize = CGSize(width: 36, height: 36)
            content.imageProperties.reservedLayoutSize = CGSize(width: 36, height: 36)
            content.imageProperties.cornerRadius = 8
            cell.contentConfiguration = content
            // The removal on its way: the shared busy accessory (#1775), on
            // the loader's timing.
            cell.accessories = self?.viewModel.removing.contains(app.id) == true ? [.busy()] : []
            self?.loadIcon(app, into: cell)
        }
        let messageRegistration = UICollectionView.CellRegistration<UICollectionViewListCell, Item> { [weak self] cell, _, item in
            var content = UIListContentConfiguration.cell()
            content.textProperties.color = .secondaryLabel
            switch item {
            case .loading:
                cell.contentConfiguration = SkeletonRowConfiguration(sample: "A row of this list")
                cell.accessories = []
                return
            case .takingLonger:
                // Past 10 s (#1770): a row a tap retries.
                content.text = TakingLongerCopy.row
            case .failed:
                content.text = FailureCopy.row(
                    for: self?.viewModel.failure, fallback: "Couldn't load your connected apps. Tap to try again."
                )
            case .empty: content.text = "No apps or websites are connected to your account."
            case .app: break
            }
            cell.contentConfiguration = content
        }
        dataSource = UICollectionViewDiffableDataSource<Int, Item>(collectionView: collectionView) { collectionView, indexPath, item in
            if case .app(let app) = item {
                return collectionView.dequeueConfiguredReusableCell(using: appRegistration, for: indexPath, item: app)
            }
            return collectionView.dequeueConfiguredReusableCell(using: messageRegistration, for: indexPath, item: item)
        }
        let footer = UICollectionView.SupplementaryRegistration<UICollectionViewListCell>(
            elementKind: UICollectionView.elementKindSectionFooter
        ) { view, _, _ in
            var content = UIListContentConfiguration.footer()
            content.text = "Apps and websites you signed in to with your account. Removing one stops it from using your account; it keeps what it already received."
            view.contentConfiguration = content
        }
        dataSource.supplementaryViewProvider = { collectionView, _, indexPath in
            collectionView.dequeueConfiguredReusableSupplementary(using: footer, for: indexPath)
        }
    }

    /// "Email address, Profile · Last used 3d ago".
    static func subtitle(for app: AuthorizedApp, now: Date = Date()) -> String {
        let use = app.lastUsedAt.map { date -> String in
            let age = RelativeAgeFormatter.short(from: date, to: now)
            return age == "now" ? "Used just now" : "Last used \(age) ago"
        } ?? "Never used"
        return "\(app.scopeSummary) · \(use)"
    }

    /// The app's icon over the placeholder glyph, once — cancelled when the
    /// cell shows another app.
    private func loadIcon(_ app: AuthorizedApp, into cell: UICollectionViewListCell) {
        let key = ObjectIdentifier(cell)
        iconTasks[key]?.cancel()
        guard let url = app.iconURL, let imagePipeline else { return }
        iconTasks[key] = Task { [weak cell] in
            let image = try? await imagePipeline.image(for: url, size: .avatar)
            guard !Task.isCancelled, let cell, var content = cell.contentConfiguration as? UIListContentConfiguration,
                  content.text == app.name else { return }
            // The icon dissolves over its ground; a failed one gives the
            // glyph back.
            content.image = image ?? Self.iconGlyph
            content.imageProperties.tintColor = image == nil ? .secondaryLabel : nil
            UIView.transition(with: cell, duration: 0.2, options: [.transitionCrossDissolve, .allowUserInteraction]) {
                cell.contentConfiguration = content
            }
        }
    }

    /// An app with no icon of its own.
    private static let iconGlyph = UIImage(systemName: "app.badge.checkmark")

    /// The list's loading on the kit's timing (#1770). Injectable so a test
    /// steps it.
    var skeletonClock: LoadingClock = .system
    private lazy var loadingGate: ListSkeletonGate = {
        let gate = ListSkeletonGate(clock: skeletonClock)
        gate.onChange = { [weak self] in self?.applySnapshot() }
        return gate
    }()

    private func applySnapshot() {
        var snapshot = NSDiffableDataSourceSnapshot<Int, Item>()
        snapshot.appendSections([0])
        switch viewModel.phase {
        case .loading:
            // The kit's timing (#1770): nothing for its delay, the bones,
            // "taking longer" past 10 s.
            switch loadingGate.loading() {
            case .bones: snapshot.appendItems([.loading])
            case .takingLonger: snapshot.appendItems([.takingLonger])
            case .nothing: break
            }
        case .failed: snapshot.appendItems([.failed])
        case .loaded(let apps) where apps.isEmpty: snapshot.appendItems([.empty])
        case .loaded(let apps):
            let items = apps.map(Item.app)
            snapshot.appendItems(items)
            snapshot.reconfigureItems(items)
        }
        let animated = view.window != nil
        if case .loading = viewModel.phase {
            dataSource.apply(snapshot, animatingDifferences: animated)
        } else {
            // The answer waits out the bones' minimum (#1770).
            loadingGate.landed { [weak self] in self?.dataSource.apply(snapshot, animatingDifferences: animated) }
        }
    }

    private func confirmRemoval(_ app: AuthorizedApp) {
        let sheet = UIAlertController(
            title: "Remove access for \(app.name)?",
            message: "It will no longer be able to use your account. It keeps what it already received.",
            preferredStyle: .actionSheet
        )
        sheet.addAction(UIAlertAction(title: "Remove Access", style: .destructive) { [weak self] _ in
            self?.remove(app)
        })
        sheet.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        if let popover = sheet.popoverPresentationController {
            popover.sourceView = view
            popover.sourceRect = CGRect(x: view.bounds.midX, y: view.bounds.maxY - 60, width: 0, height: 0)
            popover.permittedArrowDirections = []
        }
        present(sheet, animated: true)
    }

    private func remove(_ app: AuthorizedApp) {
        Task { [weak self] in
            guard let self else { return }
            do {
                try await viewModel.remove(app)
            } catch {
                let alert = UIAlertController(
                    title: nil, message: "Couldn't remove access for \(app.name). Try again.", preferredStyle: .alert
                )
                alert.addAction(UIAlertAction(title: "OK", style: .default))
                present(alert, animated: true)
            }
        }
    }
}

extension AuthorizedAppsViewController: UICollectionViewDelegate {
    func collectionView(_ collectionView: UICollectionView, shouldHighlightItemAt indexPath: IndexPath) -> Bool {
        switch dataSource.itemIdentifier(for: indexPath) {
        case .app, .failed: true
        default: false
        }
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        switch dataSource.itemIdentifier(for: indexPath) {
        case .app(let app): confirmRemoval(app)
        case .failed: Task { await viewModel.load() }
        case .takingLonger:
            loadingGate.retry()
            Task { await viewModel.load() }
        default: break
        }
    }
}
