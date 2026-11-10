import DesignSystem
import MediaCore
import UIKit

/// One tab's list, a page of the pager. Each tab its own controller, as the
/// profile's lists: during a swipe two are on screen, each with its own
/// rows, its own empty state and its own scroll.
final class PersonListPageViewController: UIViewController {
    private enum Section: Hashable { case lead, people, skeleton, paging }
    private enum Item: Hashable {
        case lead
        case person(String)
        case placeholder(Int)
        case paging
    }

    var listTab: PersonListTab {
        didSet {
            guard listTab != oldValue, isViewLoaded else { return }
            render(feed.phase)
            setNeedsUpdateContentUnavailableConfiguration()
        }
    }
    let feed: PersonListFeed
    weak var host: PersonListsViewController?
    private let imagePipeline: ImagePipeline?
    private var collectionView: UICollectionView!
    private var dataSource: UICollectionViewDiffableDataSource<Section, Item>!
    private let refreshControl = AppRefreshControl()
    private var rowsByID: [String: PersonListRow] = [:]

    init(tab: PersonListTab, feed: PersonListFeed, imagePipeline: ImagePipeline?) {
        self.listTab = tab
        self.feed = feed
        self.imagePipeline = imagePipeline
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidLoad() {
        super.viewDidLoad()
        configureList()
        feed.onChange = { [weak self] phase in
            self?.render(phase)
            self?.setNeedsUpdateContentUnavailableConfiguration()
        }
        render(feed.phase)
        // Made when the pager is about to show it: its first page now.
        feed.start()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        // The skeleton runs to the foot, and how many rows that takes is
        // only known once laid out.
        if case .loading = feed.phase { renderNow(.loading) }
    }

    private func configureList() {
        var configuration = UICollectionLayoutListConfiguration(appearance: .plain)
        configuration.showsSeparators = false
        let layout = UICollectionViewCompositionalLayout.list(using: configuration)
        collectionView = UICollectionView(frame: view.bounds, collectionViewLayout: layout)
        collectionView.delegate = self
        collectionView.alwaysBounceVertical = true
        collectionView.alwaysBounceHorizontal = false
        // Clear: the pager carries the blur (see the screen's `viewDidLoad`).
        collectionView.prefersClearTopEdge()
        collectionView.pin(to: view)
        refreshControl.addAction(UIAction { [weak self] _ in self?.feed.reload() }, for: .valueChanged)
        collectionView.refreshControl = refreshControl

        let lead = UICollectionView.CellRegistration<UICollectionViewListCell, Item> { [weak self] cell, _, _ in
            guard let action = self?.listTab.leadingAction else { return }
            var content = cell.defaultContentConfiguration()
            content.text = action.title
            content.image = UIImage(systemName: action.symbol)
            content.textProperties.color = .tintColor
            cell.contentConfiguration = content
            cell.accessibilityTraits = .button
        }
        let person = UICollectionView.CellRegistration<PersonListCell, String> { [weak self] cell, _, id in
            guard let self, let row = rowsByID[id] else { return }
            configure(cell, with: row)
        }
        let skeleton = UICollectionView.CellRegistration<PersonSkeletonCell, Int> { cell, _, index in
            cell.configure(at: index)
            // Laid out before any animation sees it (#717).
            UIView.performWithoutAnimation { cell.layoutIfNeeded() }
        }
        let paging = UICollectionView.CellRegistration<PagingFooterCell, Int> { cell, _, _ in
            cell.footer.loadingAccessibilityLabel = "Loading more people"
            cell.configure(.loading)
        }
        dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) { collectionView, path, item in
            switch item {
            case .lead: collectionView.dequeueConfiguredReusableCell(using: lead, for: path, item: item)
            case .person(let id): collectionView.dequeueConfiguredReusableCell(using: person, for: path, item: id)
            case .placeholder(let index): collectionView.dequeueConfiguredReusableCell(using: skeleton, for: path, item: index)
            case .paging: collectionView.dequeueConfiguredReusableCell(using: paging, for: path, item: 0)
            }
        }
    }

    private func configure(_ cell: PersonListCell, with row: PersonListRow) {
        cell.configure(with: PersonRowContent(displayName: row.name, handle: row.detail, monogram: row.monogram))
        cell.avatar.setPicture(row.avatarURL, pipeline: imagePipeline)
        if row.answersRequest {
            // A request's two answers, as the Requests screen draws them
            // (#2231): Approve tinted, Decline a glyph.
            let approve = AppButton(aspect: .pill(.prominent), size: .row, content: .title("Approve"))
            approve.accessibilityLabel = "Approve \(row.name)"
            let decline = AppIconButton(style: .glyph, content: .symbol("xmark"))
            decline.inkColor = .secondaryLabel
            decline.accessibilityLabel = "Decline \(row.name)"
            approve.addAction(UIAction { [weak self] _ in self?.answer(row, approve: true) }, for: .primaryActionTriggered)
            decline.addAction(UIAction { [weak self] _ in self?.answer(row, approve: false) }, for: .primaryActionTriggered)
            cell.accessories = [
                .customView(configuration: .init(customView: approve, placement: .trailing(displayed: .always), reservedLayoutWidth: .actual)),
                .customView(configuration: .init(customView: decline, placement: .trailing(displayed: .always), reservedLayoutWidth: .actual)),
            ]
            return
        }
        guard !row.actions.isEmpty else { return }
        let more = AppIconButton(style: .glyph, content: .symbol("ellipsis"))
        more.inkColor = .secondaryLabel
        more.accessibilityLabel = "Manage \(row.name)"
        more.addAction(UIAction { [weak self, weak more] _ in self?.presentMenu(for: row, from: more) }, for: .primaryActionTriggered)
        cell.accessories.append(.customView(configuration: .init(
            customView: more, placement: .trailing(displayed: .always), reservedLayoutWidth: .actual
        )))
    }

    // MARK: - Render

    /// The first page's skeleton on the kit's timing (#1770), as the
    /// profile's lists: no bones for a list that answers at once, held their
    /// minimum once up.
    private lazy var skeletonGate: SkeletonGate = {
        let gate = SkeletonGate()
        gate.onSkeletonChange = { [weak self] _ in
            guard let self, case .loading = feed.phase else { return }
            renderNow(.loading)
        }
        return gate
    }()

    private func render(_ phase: PersonListFeed.Phase) {
        guard isViewLoaded else { return }
        guard case .loading = phase else {
            return skeletonGate.finish { [weak self] in
                guard let self else { return }
                renderNow(feed.phase)
                setNeedsUpdateContentUnavailableConfiguration()
            }
        }
        skeletonGate.begin()
        renderNow(phase)
    }

    /// The phase on screen: the feed's, once the bones have gone.
    private var shownPhase: PersonListFeed.Phase = .loading

    private func renderNow(_ phase: PersonListFeed.Phase) {
        guard isViewLoaded else { return }
        shownPhase = phase
        var snapshot = NSDiffableDataSourceSnapshot<Section, Item>()
        if listTab.leadingAction != nil {
            snapshot.appendSections([.lead])
            snapshot.appendItems([.lead], toSection: .lead)
        }
        var rows: [PersonListRow] = []
        switch phase {
        case .loading:
            if skeletonGate.showsSkeleton {
                let count = PersonSkeletonCell.rowsToFill(max(view.bounds.height, 1))
                snapshot.appendSections([.skeleton])
                snapshot.appendItems((0..<max(1, count)).map(Item.placeholder), toSection: .skeleton)
            }
        case .content(let shown, let isLoadingMore):
            rows = shown
            snapshot.appendSections([.people])
            snapshot.appendItems(shown.map { .person($0.id) }, toSection: .people)
            if isLoadingMore {
                snapshot.appendSections([.paging])
                snapshot.appendItems([.paging], toSection: .paging)
            }
        case .empty, .failed:
            break
        }
        if case .loading = phase {} else { refreshControl.endRefreshing() }
        let before = rowsByID
        rowsByID = Dictionary(rows.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let changed = rows.filter { before[$0.id] != nil && before[$0.id] != $0 }.map { Item.person($0.id) }
        snapshot.reconfigureItems(changed)
        if listTab.leadingAction != nil { snapshot.reconfigureItems([.lead]) }
        dataSource.apply(snapshot, animatingDifferences: false)
    }

    /// Never a header over nothing: an empty tab says so, a failed one
    /// offers Try Again — the platform's own block, as on the profile.
    override func updateContentUnavailableConfiguration(using state: UIContentUnavailableConfigurationState) {
        switch shownPhase {
        case .empty:
            var empty = UIContentUnavailableConfiguration.empty()
            empty.image = UIImage(systemName: listTab.empty.symbol)
            empty.text = listTab.empty.title
            empty.secondaryText = listTab.empty.message
            contentUnavailableConfiguration = empty
        case .failed(let message):
            var failed = UIContentUnavailableConfiguration.empty()
            failed.image = UIImage(systemName: "exclamationmark.triangle")
            failed.text = "Couldn't Load"
            failed.secondaryText = message
            var button = UIButton.Configuration.borderless()
            button.title = "Try Again"
            failed.button = button
            failed.buttonProperties.primaryAction = UIAction { [weak self] _ in self?.feed.reload() }
            contentUnavailableConfiguration = failed
        case .loading, .content:
            contentUnavailableConfiguration = nil
        }
    }

    // MARK: - Actions

    private func presentMenu(for row: PersonListRow, from anchor: UIView?) {
        let sheet = UIAlertController(title: row.name, message: nil, preferredStyle: .actionSheet)
        for action in row.actions {
            sheet.addAction(UIAlertAction(title: action.title, style: action.isDestructive ? .destructive : .default) {
                [weak self] _ in self?.perform(action, on: row)
            })
        }
        sheet.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        sheet.popoverPresentationController?.sourceView = anchor ?? view
        present(sheet, animated: true)
    }

    private func perform(_ action: PersonListRowAction, on row: PersonListRow) {
        guard let host else { return }
        host.sourceForPages?.perform(action, on: row, in: listTab.id, from: host)
    }

    private func answer(_ row: PersonListRow, approve: Bool) {
        guard let host else { return }
        host.sourceForPages?.answer(row, approve: approve, in: listTab.id, from: host)
    }
}

extension PersonListPageViewController: UICollectionViewDelegate {
    /// The next page as the end comes into view, three rows ahead; asked a
    /// runloop turn later, never inside `willDisplay`'s layout.
    func collectionView(_ collectionView: UICollectionView, willDisplay cell: UICollectionViewCell, forItemAt indexPath: IndexPath) {
        guard case .person = dataSource.itemIdentifier(for: indexPath) else { return }
        let count = collectionView.numberOfItems(inSection: indexPath.section)
        guard indexPath.item >= count - 3 else { return }
        DispatchQueue.main.async { [weak self] in self?.feed.loadMoreIfNeeded() }
    }

    func collectionView(_ collectionView: UICollectionView, shouldSelectItemAt indexPath: IndexPath) -> Bool {
        switch dataSource.itemIdentifier(for: indexPath) {
        case .lead: true
        case .person(let id): rowsByID[id]?.opens == true
        default: false
        }
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        guard let host, let source = host.sourceForPages else { return }
        switch dataSource.itemIdentifier(for: indexPath) {
        case .lead:
            source.performLeadingAction(in: listTab.id, from: host)
        case .person(let id):
            guard let row = rowsByID[id], row.opens else { return }
            source.open(row, in: listTab.id, from: host)
        default:
            break
        }
    }

    /// A row's "⋯" on a long press too.
    func collectionView(
        _ collectionView: UICollectionView, contextMenuConfigurationForItemsAt indexPaths: [IndexPath], point: CGPoint
    ) -> UIContextMenuConfiguration? {
        guard let path = indexPaths.first, case .person(let id) = dataSource.itemIdentifier(for: path),
              let row = rowsByID[id], !row.actions.isEmpty else { return nil }
        return UIContextMenuConfiguration(actionProvider: { [weak self] _ in
            UIMenu(children: row.actions.map { action in
                UIAction(title: action.title, attributes: action.isDestructive ? .destructive : []) { _ in
                    self?.perform(action, on: row)
                }
            })
        })
    }
}
