import CoreModels
import DesignSystem
import MediaCore
import MediaUI
import UIKit

/// The "New message" sheet (#2411): opened at its large detent from the
/// inbox's compose item, titled, with ✕ to close. "Search people" in the
/// sheet's bar — not focused at the opening, so the people show first —
/// then the actions and the people, as `NewMessageViewModel` sections them.
///
/// The rows are the app's shared person row (`PersonListCell`) wearing the
/// relation mark (#2049) — the inbox rows' — and the action rows are the
/// same anatomy with a glyph for a face, as the inbox search drew them. The
/// headers are the inbox search's glass capsules, pinned over the rows.
///
/// Loading draws skeleton rows where the loaded rows stop, on the kit's
/// timing (`SkeletonGate`, #1770: nothing for 0.15 s, held 0.3 s once up,
/// gone after 10 s), with the kit's `PersonSkeletonCell`, never over them.
final class NewMessageViewController: UIViewController {
    private enum ListSection: Hashable {
        case content(NewMessageViewModel.SectionKind)
        case loading

        /// Whether it wears a header: every section of people does.
        var isHeaded: Bool {
            switch self {
            case .content(let kind): kind != .actions
            case .loading: false
            }
        }
    }

    private enum ListItem: Hashable {
        case row(NewMessageViewModel.Row)
        case skeleton(Int)
    }

    /// The close item's identifier (the bar contract, R2).
    static let closeItemID = "messages.new-message.close"
    /// What the sheet's bar says.
    static let sheetTitle = "New message"
    /// What the empty field says.
    static let searchPlaceholder = "Search people"
    /// How close to the end of Suggested a row has to come into view to ask
    /// for the next page.
    static let nearEndRowCount = 5

    private let viewModel: NewMessageViewModel
    private let relations: InboxRelations?
    private let faces: PersonRowFaces

    /// ✕: the host closes the sheet.
    var onClose: (() -> Void)?

    private var collectionView: UICollectionView!
    private var dataSource: UICollectionViewDiffableDataSource<ListSection, ListItem>!
    private let statusView = InboxStatusView()
    private var sectionKinds: [ListSection] = []
    private var titles: [NewMessageViewModel.SectionKind: String] = [:]
    private var hasRendered = false

    private lazy var searchController: UISearchController = {
        let controller = UISearchController(searchResultsController: nil)
        controller.searchResultsUpdater = self
        controller.obscuresBackgroundDuringPresentation = false
        // The title and ✕ stay while typing: the sheet is the search.
        controller.hidesNavigationBarDuringPresentation = false
        let bar = controller.searchBar
        bar.placeholder = Self.searchPlaceholder
        bar.autocapitalizationType = .none
        bar.autocorrectionType = .no
        bar.returnKeyType = .search
        bar.searchTextField.accessibilityIdentifier = "messages.new-message.search"
        return controller
    }()

    init(
        viewModel: NewMessageViewModel,
        imagePipeline: ImagePipeline?,
        avatars: (any PeerAvatarProviding)?,
        relations: InboxRelations?
    ) {
        self.viewModel = viewModel
        self.relations = relations
        // The faces the rows read are kept for the thread they open (#2049).
        faces = PersonRowFaces(avatars: relations?.recording(avatars) ?? avatars, imagePipeline: imagePipeline)
        super.init(nibName: nil, bundle: nil)
        title = Self.sheetTitle
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        // ⚠️ `.never`, not `.inline`: iOS 26 resolves `.inline` back to the
        // big stacked title in a sheet, and a large title plus a search
        // field leaves the bar so little room that its items go into a `•••`.
        navigationItem.largeTitleDisplayMode = .never
        navigationItem.leftBarButtonItem = BarItems.icon(
            id: Self.closeItemID, image: UIImage(systemName: "xmark"), label: "Close"
        ) { [weak self] in self?.onClose?() }
        definesPresentationContext = true
        navigationItem.searchController = searchController
        navigationItem.preferredSearchBarPlacement = .stacked
        navigationItem.hidesSearchBarWhenScrolling = false
        configureList()
        configureStatusView()
        viewModel.onStateChange = { [weak self] state in self?.render(state) }
        relations?.observe(by: self) { [weak self] peers in self?.applyRelations(of: peers) }
        render(viewModel.state)
        viewModel.start()
    }

    // MARK: - Layout

    private func configureList() {
        let layout = UICollectionViewCompositionalLayout { [weak self] index, environment in
            var configuration = UICollectionLayoutListConfiguration(appearance: .plain)
            configuration.showsSeparators = false
            let headed = self?.sectionKinds[safe: index]?.isHeaded ?? false
            configuration.headerMode = headed ? .supplementary : .none
            configuration.headerTopPadding = index == 0
                ? 0
                : SectionHeaderPillButton.sectionGap(traits: environment.traitCollection)
            return NSCollectionLayoutSection.list(using: configuration, layoutEnvironment: environment)
        }
        collectionView = UICollectionView(frame: view.bounds, collectionViewLayout: layout)
        collectionView.delegate = self
        collectionView.keyboardDismissMode = .onDrag
        // A titled sheet: the soft edge under its bar (#1591).
        collectionView.applyTopEdge(for: .titled)
        collectionView.pin(to: view)

        let personCell = UICollectionView.CellRegistration<PersonListCell, ProfileID> { [weak self] cell, _, id in
            guard let self, let person = self.viewModel.people[id] else { return }
            // The marked face first: the slot holds one kind for the cell's life.
            let face = cell.markedAvatar
            cell.configure(with: person.rowContent)
            face.setMark(self.relations?.mark(for: id) ?? .none, animated: false)
            // The face's "+" follows, as on the inbox rows (#2049).
            face.onFollowTapped = { [weak self] in
                guard let self else { return }
                self.relations?.follow(id, handle: person.handle, name: person.displayName, from: self)
            }
            self.faces.lookUp(id, into: cell)
        }
        let actionCell = UICollectionView.CellRegistration<PersonListCell, NewMessageViewModel.Row> { cell, _, row in
            cell.configure(with: Self.actionContent(row))
        }
        let skeletonCell = UICollectionView.CellRegistration<PersonSkeletonCell, Int> { cell, _, index in
            cell.configure(at: index)
        }
        let header = UICollectionView.SupplementaryRegistration<SectionHeaderCapsuleView>(
            elementKind: UICollectionView.elementKindSectionHeader
        ) { [weak self] view, _, indexPath in
            guard let self, case .content(let kind)? = self.sectionKinds[safe: indexPath.section] else {
                view.setTitle(nil)
                return
            }
            view.setTitle(self.titles[kind])
        }
        dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) { list, indexPath, item in
            switch item {
            case .skeleton(let index):
                return list.dequeueConfiguredReusableCell(using: skeletonCell, for: indexPath, item: index)
            case .row(.person(let id)):
                return list.dequeueConfiguredReusableCell(using: personCell, for: indexPath, item: id)
            case .row(let row):
                return list.dequeueConfiguredReusableCell(using: actionCell, for: indexPath, item: row)
            }
        }
        dataSource.supplementaryViewProvider = { list, _, indexPath in
            list.dequeueConfiguredReusableSupplementary(using: header, for: indexPath)
        }
    }

    private func configureStatusView() {
        statusView.isHidden = true
        // Centred in what the keyboard leaves: the field is focused when
        // there is nothing to offer, and a query is typed with it up.
        statusView.constrain(in: view) { parent in
            statusView.topAnchor.constraint(equalTo: parent.safeAreaLayoutGuide.topAnchor)
            statusView.leadingAnchor.constraint(equalTo: parent.leadingAnchor)
            statusView.trailingAnchor.constraint(equalTo: parent.trailingAnchor)
            statusView.bottomAnchor.constraint(equalTo: parent.keyboardLayoutGuide.topAnchor)
        }
    }

    /// An action row: the people rows' anatomy, a glyph for a face.
    static func actionContent(_ row: NewMessageViewModel.Row) -> PersonRowContent {
        switch row {
        case .newChannel:
            PersonRowContent(
                displayName: "New channel", handle: ChannelCopy.newChannelMessage, monogram: "",
                subject: .symbol(AppSymbol.megaphoneFill.rawValue)
            )
        default:
            PersonRowContent(
                displayName: "New group", handle: "Talk with several people at once", monogram: "",
                subject: .symbol("person.2.fill")
            )
        }
    }

    // MARK: - Render

    // MARK: - The bones' timing (#1770)

    /// The loading kit's clock; a test steps it.
    var skeletonClock: LoadingClock = .system
    private lazy var skeletonGate: SkeletonGate = {
        let gate = SkeletonGate(clock: skeletonClock)
        gate.onSkeletonChange = { [weak self] _ in self?.renderNow() }
        // Past 10 s the bones go, as Search's Suggested does: the rows on
        // show and the field still work.
        gate.onTakingLonger = { [weak self] in
            self?.bonesGaveUp = true
            self?.skeletonGate.finish { [weak self] in self?.renderNow() }
        }
        return gate
    }()
    /// The wait ran past 10 s: no bones again until a load answers.
    private var bonesGaveUp = false
    /// The view model's last state, drawn when the gate says.
    private var latestState = NewMessageViewModel.State()

    /// A state from the view model: while a source is out the gate runs and
    /// the rows draw now, the bones when it says; once everything answered,
    /// the list lands once the bones had their minimum.
    private func render(_ state: NewMessageViewModel.State) {
        latestState = state
        guard isViewLoaded else { return }
        if state.isLoading {
            if !bonesGaveUp { skeletonGate.begin() }
            renderNow()
        } else {
            bonesGaveUp = false
            skeletonGate.finish { [weak self] in self?.renderNow() }
        }
    }

    /// The latest state, with the bones only while the gate shows them.
    private func renderNow() {
        guard isViewLoaded else { return }
        let state = latestState
        var snapshot = NSDiffableDataSourceSnapshot<ListSection, ListItem>()
        titles = [:]
        for section in state.sections {
            snapshot.appendSections([.content(section.kind)])
            snapshot.appendItems(section.rows.map(ListItem.row), toSection: .content(section.kind))
            titles[section.kind] = section.title
        }
        if state.isLoading, skeletonGate.showsSkeleton, !bonesGaveUp {
            snapshot.appendSections([.loading])
            snapshot.appendItems((0..<skeletonRowCount(after: state)).map(ListItem.skeleton), toSection: .loading)
        }
        sectionKinds = snapshot.sectionIdentifiers
        // A person shown again keeps its row, told its model (a friend who
        // is also a suggestion moves up).
        let shown = Set(dataSource.snapshot().itemIdentifiers)
        snapshot.reconfigureItems(snapshot.itemIdentifiers.filter { shown.contains($0) && Self.isPerson($0) })
        dataSource.apply(snapshot, animatingDifferences: hasRendered && view.window != nil)
        hasRendered = true
        renderStatus(state.status)
    }

    private static func isPerson(_ item: ListItem) -> Bool {
        guard case .row(.person) = item else { return false }
        return true
    }

    /// Enough bones to fill what the loaded rows leave of the screen.
    private func skeletonRowCount(after state: NewMessageViewModel.State) -> Int {
        let rows = state.sections.reduce(0) { $0 + $1.rows.count }
        let viewport = collectionView.bounds.height > 0 ? collectionView.bounds.height : view.bounds.height
        let left = viewport - CGFloat(rows) * PersonListCell.comfortableRowHeight
        return max(2, PersonSkeletonCell.rowsToFill(left))
    }

    /// The status last shown, so the field is focused once, as it starts.
    private var shownStatus: NewMessageViewModel.Status = .none

    private func renderStatus(_ status: NewMessageViewModel.Status) {
        defer { shownStatus = status }
        switch status {
        case .none:
            statusView.isHidden = true
        case .searchForSomeone:
            statusView.configure(
                symbol: AppSymbol.search.rawValue, title: "Search for someone",
                message: "Find someone to write to by name or handle."
            )
            statusView.isHidden = false
            // Nothing to pick from: the field is where to start.
            guard shownStatus != .searchForSomeone else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.view.window != nil else { return }
                self.searchController.searchBar.searchTextField.becomeFirstResponder()
            }
        case .noPeople:
            statusView.configure(
                symbol: AppSymbol.search.rawValue, title: "No people found",
                message: "No one matches that name or handle."
            )
            statusView.isHidden = false
        case .failed(let message):
            statusView.configure(
                symbol: "exclamationmark.triangle", title: "Something went wrong", message: message,
                actionTitle: "Try Again", action: { [weak self] in self?.viewModel.retry() }
            )
            statusView.isHidden = false
        }
    }

    // MARK: - The relation mark (#2049)

    /// The rows on screen whose person's relation changed. `peers` nil:
    /// every row (a viewer change).
    private func applyRelations(of peers: Set<ProfileID>?) {
        guard let relations else { return }
        for indexPath in collectionView.indexPathsForVisibleItems {
            guard case .row(.person(let id)) = dataSource.itemIdentifier(for: indexPath),
                  peers?.contains(id) ?? true,
                  let cell = collectionView.cellForItem(at: indexPath) as? PersonListCell else { continue }
            cell.markedAvatar.setMark(relations.mark(for: id), animated: true)
        }
    }

    #if DEBUG
    /// The field's text, as typed (#2411). QA and tests.
    func debugType(_ text: String) {
        searchController.searchBar.text = text
        viewModel.queryChanged(text)
    }
    /// The sections on show, in order. Tests.
    var debugSectionKinds: [NewMessageViewModel.SectionKind] {
        sectionKinds.compactMap { section -> NewMessageViewModel.SectionKind? in
            guard case .content(let kind) = section else { return nil }
            return kind
        }
    }
    /// Whether the skeleton closes the list. Tests.
    var debugShowsSkeleton: Bool { sectionKinds.contains(.loading) }
    /// The status message's title on show, nil when hidden. Tests.
    var debugStatusShown: Bool { !statusView.isHidden }
    #endif
}

extension NewMessageViewController: UISearchResultsUpdating {
    func updateSearchResults(for searchController: UISearchController) {
        viewModel.queryChanged(searchController.searchBar.text ?? "")
    }
}

extension NewMessageViewController: UICollectionViewDelegate {
    func collectionView(
        _ collectionView: UICollectionView, willDisplay cell: UICollectionViewCell, forItemAt indexPath: IndexPath
    ) {
        guard case .row(.person(let id)) = dataSource.itemIdentifier(for: indexPath) else { return }
        // Where the viewer stands with this person, for the face's mark
        // (#2049). Asked once; the cache dedups.
        relations?.resolve([id])
        guard sectionKinds[safe: indexPath.section] == .content(.suggested),
              indexPath.item >= collectionView.numberOfItems(inSection: indexPath.section) - Self.nearEndRowCount
        else { return }
        // Deferred: the next page's snapshot must not be applied from inside
        // this display pass.
        DispatchQueue.main.async { [weak self] in self?.viewModel.loadMoreSuggestions() }
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        guard case .row(let row) = dataSource.itemIdentifier(for: indexPath) else { return }
        if case .person = row {
            // The sheet is going and a thread coming: a second tap in that
            // window would push a second one.
            collectionView.allowsSelection = false
        }
        viewModel.didSelect(row)
    }

    func collectionView(_ collectionView: UICollectionView, shouldHighlightItemAt indexPath: IndexPath) -> Bool {
        if case .skeleton = dataSource.itemIdentifier(for: indexPath) { return false }
        return true
    }
}

extension NewMessageViewController: StackScreen {
    /// The sheet's root: ✕, or the sheet's swipe down.
    var leaving: ScreenLeaving { .controlsOnly }
}

private extension Array {
    /// Index-path bounds outlive the snapshot that produced them.
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
