import CoreModels
import DesignSystem
import UIKit

/// The compose picker: search the directory, or pick someone off the two lists
/// the app already knows about.
///
/// Search results replace the browsing sections *in the same collection view*
/// rather than arriving in a `searchResultsController`. One data source means
/// the transition between "who you talk to" and "who you searched for" is a
/// diffable apply — rows animate into place — instead of a second controller
/// sliding over the first, which is the seam that makes most search screens
/// feel bolted together.
final class NewMessageViewController: UIViewController {
    private typealias SectionKind = NewMessageViewModel.Section.Kind

    /// Section-scoped, because a diffable data source requires item identifiers
    /// to be unique across the WHOLE snapshot, not per section. A profile id
    /// alone would trap the moment anyone appeared in two sections.
    private enum Item: Hashable {
        case person(SectionKind, ProfileID)
        /// A loading row. Ordinary items in an ordinary section, so the layout
        /// places them after the rows that have loaded — no measuring, and no
        /// way for them to overlap real content.
        case placeholder(Int)
        /// The paging spinner, in a trailing section of its own so that
        /// appending it never shifts the item indices the pagination trigger
        /// reads off the suggested section.
        case pagingSpinner
    }

    /// The diffable section identifier. The placeholder rows need a section of
    /// their own — borrowing one of the view model's would let a snapshot
    /// append the same identifier twice and trap, the moment the loading flag
    /// and that section were ever live together.
    private enum ListSection: Hashable {
        case model(SectionKind)
        case placeholder
        case pagingSpinner
    }

    private let viewModel: NewMessageViewModel

    private let searchDock = SearchDockView()
    private var collectionView: UICollectionView!
    private let statusView = InboxStatusView()

    private var dataSource: UICollectionViewDiffableDataSource<ListSection, Item>!
    private var modelsByItem: [Item: PersonDisplayModel] = [:]
    private var sectionTitles: [ListSection: String] = [:]
    private var visibleSections: [ListSection] = []
    private var hasRenderedContent = false
    #if DEBUG
    /// `-new-message-pick`'s target, fired on the first render that contains it.
    private var pendingDebugPick: ProfileID?
    #endif

    init(viewModel: NewMessageViewModel) {
        self.viewModel = viewModel
        super.init(nibName: nil, bundle: nil)
        // Compose is a focused, dead-end task, and every other pushed screen in
        // the app already does this (`ProfileViewController`,
        // `ConversationViewController`). Without it the tab bar survived
        // inbox → picker and then vanished on picker → thread, putting the one
        // bar transition in the middle of the flow instead of at its start.
        hidesBottomBarWhenPushed = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "New Message"
        view.backgroundColor = .systemBackground
        // Inline, so the picker's bar matches the inbox it was pushed from and
        // leaves the Back button room beside the search field. (`.never` rather
        // than `.inline`: iOS 26 resolves `.inline` back to the big stacked
        // header, which then squeezes bar items into an overflow "•••" menu.)
        navigationItem.largeTitleDisplayMode = .never

        configureCollectionView()
        configureSearchDock()
        configureStatusViews()

        viewModel.onPhaseChange = { [weak self] phase in self?.render(phase) }
        render(.loading)
        viewModel.load()

        #if DEBUG
        // Dev convenience, mirroring `-search-query` on the people-search tab:
        // seeds the field on launch so the results path is reachable without
        // driving the simulator's keyboard.
        if let index = ProcessInfo.processInfo.arguments.firstIndex(of: "-new-message-query"),
           index + 1 < ProcessInfo.processInfo.arguments.count {
            searchDock.text = ProcessInfo.processInfo.arguments[index + 1]
        }
        // `-new-message-pick <profile-id>` picks a row as soon as one showing
        // that person renders. Row taps can't be injected in-sim, and this is
        // the seam worth driving end to end: pick → push the thread →
        // find-or-create underneath it, three objects each owning one step.
        //
        // Driven by content rather than a timer: under `-mock-latency` the
        // lists can take seconds to arrive, and a fixed delay fires into a
        // still-loading picker where the tap is silently dropped.
        if let index = ProcessInfo.processInfo.arguments.firstIndex(of: "-new-message-pick"),
           index + 1 < ProcessInfo.processInfo.arguments.count {
            pendingDebugPick = ProfileID(ProcessInfo.processInfo.arguments[index + 1])
        }
        #endif
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        // Re-armed here rather than after the push: selection is disabled on
        // tap so a second tap during the push transition can't stack a second
        // thread, and popping back is exactly when the picker becomes usable
        // again.
        collectionView.allowsSelection = true
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        // The keyboard belongs to a screen that is leaving. The field itself
        // needs no handling: it is a subview of this screen, so it travels with
        // the transition like everything else on it — which is what a
        // navigation-bar search palette could never do.
        searchDock.resignFirstResponder()
    }

    /// Keeps the list clear of the docked field.
    ///
    /// Derived from where the dock actually IS rather than from its height, so
    /// one expression covers both resting and keyboard-raised: the dock rides
    /// `keyboardLayoutGuide`, and this measures the gap it leaves behind it.
    /// The safe-area part is subtracted because `adjustedContentInset` already
    /// counts it.
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let clearance = view.bounds.maxY - searchDock.frame.minY + Spacing.sm
        let inset = max(0, clearance - view.safeAreaInsets.bottom)
        guard abs(collectionView.contentInset.bottom - inset) > 0.5 else { return }
        collectionView.contentInset.bottom = inset
        collectionView.verticalScrollIndicatorInsets.bottom = inset
    }

    // MARK: - Setup

    private func configureSearchDock() {
        searchDock.onQueryChange = { [weak self] query in self?.viewModel.queryChanged(query) }
        searchDock.constrain(in: view) { parent in
            searchDock.leadingAnchor.constraint(equalTo: parent.layoutMarginsGuide.leadingAnchor)
            searchDock.trailingAnchor.constraint(equalTo: parent.layoutMarginsGuide.trailingAnchor)
            // The guide tracks the keyboard, including interactive dismissal
            // scrubs, so the field rides it with no keyboard math — the same
            // dock `ChatInputBar` uses one screen further along.
            searchDock.bottomAnchor.constraint(
                equalTo: parent.keyboardLayoutGuide.topAnchor, constant: -Spacing.sm
            )
        }
    }

    private func configureCollectionView() {
        // Built per section rather than from one list configuration: search
        // results carry no header, and `headerMode = .supplementary` applied
        // globally would reserve an empty header band above them.
        let layout = UICollectionViewCompositionalLayout { [weak self] index, environment in
            var configuration = UICollectionLayoutListConfiguration(appearance: .plain)
            configuration.headerMode = self?.title(forSectionAt: index) == nil ? .none : .supplementary
            // Only the FIRST header loses its top padding. That padding is what
            // separates one section from the rows of the one above it, so
            // zeroing it everywhere would run Suggested straight into the last
            // Recent row; at the top of the list there is nothing above to
            // separate from, and the gap just pushes the content down.
            if index == 0 { configuration.headerTopPadding = 0 }
            return NSCollectionLayoutSection.list(using: configuration, layoutEnvironment: environment)
        }

        collectionView = UICollectionView(frame: view.bounds, collectionViewLayout: layout)
        collectionView.delegate = self
        collectionView.keyboardDismissMode = .onDrag
        collectionView.pin(to: view)

        let cellRegistration = UICollectionView.CellRegistration<PersonListCell, Item> {
            [weak self] cell, _, item in
            guard let self, let model = self.modelsByItem[item] else { return }
            cell.configure(with: model)
        }

        let skeletonRegistration = UICollectionView.CellRegistration<PersonSkeletonCell, Int> {
            cell, _, index in
            cell.configure(at: index)
        }

        let spinnerRegistration = UICollectionView.CellRegistration<PagingSpinnerCell, Int> {
            cell, _, _ in
            cell.startAnimating()
        }

        // A plain list pins its headers, so rows pass DIRECTLY under this one.
        // `SectionHeaderCapsuleView` carries its own glass, and its clear
        // background is what lets the rows show through around it.
        let headerRegistration = UICollectionView.SupplementaryRegistration<SectionHeaderCapsuleView>(
            elementKind: UICollectionView.elementKindSectionHeader
        ) { [weak self] header, _, indexPath in
            header.setTitle(self?.title(forSectionAt: indexPath.section))
            // Captured by SECTION, not by index path: the header is reused and
            // its index path is only valid for this configure pass, whereas the
            // section it names survives the snapshots that reshuffle rows
            // beneath it.
            let section = self?.visibleSections[safe: indexPath.section]
            header.onTap = { [weak self] in
                guard let self, let section else { return }
                self.scrollToTop(of: section)
            }
        }

        dataSource = UICollectionViewDiffableDataSource<ListSection, Item>(
            collectionView: collectionView
        ) { collectionView, indexPath, item in
            switch item {
            case .person:
                return collectionView.dequeueConfiguredReusableCell(
                    using: cellRegistration, for: indexPath, item: item
                )
            case .placeholder(let index):
                return collectionView.dequeueConfiguredReusableCell(
                    using: skeletonRegistration, for: indexPath, item: index
                )
            case .pagingSpinner:
                return collectionView.dequeueConfiguredReusableCell(
                    using: spinnerRegistration, for: indexPath, item: 0
                )
            }
        }
        dataSource.supplementaryViewProvider = { collectionView, _, indexPath in
            collectionView.dequeueConfiguredReusableSupplementary(using: headerRegistration, for: indexPath)
        }
    }

    private func configureStatusViews() {
        statusView.isHidden = true
        // Bounded by the DOCK, not the safe area. `InboxStatusView` centres its
        // column in whatever space it is given, so pinning it to the safe area
        // centred "No people found" in the whole screen — behind the search
        // field, and behind the keyboard above it. The dock rides
        // `keyboardLayoutGuide`, so bounding the status view by its top edge
        // makes the message centre in the space actually left over, and follow
        // the keyboard up and down for free.
        statusView.constrain(in: view) { parent in
            statusView.topAnchor.constraint(equalTo: parent.safeAreaLayoutGuide.topAnchor)
            statusView.leadingAnchor.constraint(equalTo: parent.leadingAnchor)
            statusView.trailingAnchor.constraint(equalTo: parent.trailingAnchor)
            statusView.bottomAnchor.constraint(
                equalTo: searchDock.dockTopAnchor, constant: -Spacing.sm
            )
        }
    }

    private func title(forSectionAt index: Int) -> String? {
        guard visibleSections.indices.contains(index) else { return nil }
        return sectionTitles[visibleSections[index]]
    }

    // MARK: - Render

    private func render(_ phase: NewMessageViewModel.Phase) {
        switch phase {
        case .loading:
            statusView.isHidden = true
            apply([], loading: .fillingScreen)

        case .content(let sections, let loading):
            statusView.isHidden = true
            apply(sections, loading: loading)
            #if DEBUG
            if let picked = pendingDebugPick,
               sections.contains(where: { $0.people.contains { $0.id == picked } }) {
                pendingDebugPick = nil
                viewModel.didSelect(picked)
            }
            #endif

        case .noResults(let query):
            apply([], loading: .none)
            showStatus(
                symbol: "magnifyingglass",
                title: "No people found",
                message: "Nobody matches “\(query)”."
            )

        case .empty:
            apply([], loading: .none)
            showStatus(
                symbol: "person.2",
                title: "No one to message yet",
                message: "Search for someone by name or @handle to start a conversation."
            )

        case .failed(let message):
            apply([], loading: .none)
            showStatus(symbol: "exclamationmark.triangle", title: "Something went wrong", message: message)
        }
    }

    private func apply(
        _ sections: [NewMessageViewModel.Section],
        loading: NewMessageViewModel.Loading
    ) {
        visibleSections = sections.map { .model($0.kind) }
        sectionTitles = sections.reduce(into: [:]) { titles, section in
            titles[.model(section.kind)] = section.title
        }
        modelsByItem = sections.reduce(into: [:]) { models, section in
            for person in section.people {
                models[.person(section.kind, person.id)] = person
            }
        }

        var snapshot = NSDiffableDataSourceSnapshot<ListSection, Item>()
        for section in sections {
            snapshot.appendSections([.model(section.kind)])
            snapshot.appendItems(
                section.people.map { Item.person(section.kind, $0.id) },
                toSection: .model(section.kind)
            )
        }

        let loadedRows = sections.reduce(0) { $0 + $1.people.count }
        let placeholders = loading == .fillingScreen ? placeholderCount(after: loadedRows) : 0
        if placeholders > 0 {
            visibleSections.append(.placeholder)
            snapshot.appendSections([.placeholder])
            // Numbered from the loaded row count so the bone-width cycle
            // continues the list rather than restarting under it.
            snapshot.appendItems(
                (loadedRows..<(loadedRows + placeholders)).map(Item.placeholder),
                toSection: .placeholder
            )
        }

        if loading == .appendingSuggestions {
            visibleSections.append(.pagingSpinner)
            snapshot.appendSections([.pagingSpinner])
            snapshot.appendItems([.pagingSpinner], toSection: .pagingSpinner)
        }

        // Animate only once there is something to animate from, and only while
        // on screen — an off-screen apply would replay its animation the next
        // time this screen is pushed.
        dataSource.apply(snapshot, animatingDifferences: hasRenderedContent && view.window != nil)
        hasRenderedContent = true
    }

    /// Scrolls `section` up to just under the navigation bar.
    ///
    /// Offset arithmetic rather than `scrollToItem(at:.top)`: that would put the
    /// section's FIRST ROW at the top, and the pinned header would then sit
    /// squarely on top of it. What the viewer means by "take me to Suggested"
    /// is the header, so the target is the first row's origin backed off by the
    /// header's own height.
    private func scrollToTop(of section: ListSection) {
        guard let index = visibleSections.firstIndex(of: section),
              collectionView.numberOfItems(inSection: index) > 0
        else { return }

        let first = IndexPath(item: 0, section: index)
        guard let row = collectionView.layoutAttributesForItem(at: first) else { return }
        let headerHeight = collectionView.layoutAttributesForSupplementaryElement(
            ofKind: UICollectionView.elementKindSectionHeader, at: first
        )?.frame.height ?? 0

        let top = -collectionView.adjustedContentInset.top
        // The furthest the list can actually travel; without the clamp the last
        // section would rubber-band and settle back, which reads as the tap
        // having been ignored.
        let bottom = max(top, collectionView.contentSize.height
            + collectionView.adjustedContentInset.bottom
            - collectionView.bounds.height)
        let target = min(max(row.frame.minY - headerHeight + top, top), bottom)
        collectionView.setContentOffset(CGPoint(x: 0, y: target), animated: true)
    }

    /// How many loading rows it takes to reach the bottom of the screen from
    /// where the loaded ones stop.
    ///
    /// Derived from the viewport rather than a fixed tally, so the list runs to
    /// the bottom edge on every device instead of stopping short on the tall
    /// ones. Rows are estimated at their resting height — being a row out
    /// either way only ever shows or hides bones at the very bottom, where the
    /// last one is clipped by the screen anyway.
    private func placeholderCount(after loadedRows: Int) -> Int {
        let viewport = collectionView.bounds.height - collectionView.adjustedContentInset.top
        return max(0, PersonSkeletonCell.rowsToFill(viewport) - loadedRows)
    }

    private func showStatus(symbol: String, title: String, message: String) {
        // The list stays visible and simply empty: hiding it would take the
        // search bar's scroll context with it.
        statusView.configure(symbol: symbol, title: title, message: message)
        statusView.isHidden = false
    }

}

extension NewMessageViewController: UICollectionViewDelegate {
    /// Asks for the next page as the end of the suggestions comes into view.
    ///
    /// Three rows of runway rather than the very last one, so the page is
    /// usually in hand by the time the viewer reaches the bottom and the list
    /// simply continues. The view model absorbs the repeat calls this fires on
    /// every bounce and every row scrolled back into view.
    func collectionView(
        _ collectionView: UICollectionView,
        willDisplay cell: UICollectionViewCell,
        forItemAt indexPath: IndexPath
    ) {
        guard case .person(.suggested, _) = dataSource.itemIdentifier(for: indexPath) else { return }
        let rowsInSection = collectionView.numberOfItems(inSection: indexPath.section)
        guard indexPath.item >= rowsInSection - 3 else { return }
        viewModel.loadMoreSuggestionsIfNeeded()
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        guard case .person(_, let id) = dataSource.itemIdentifier(for: indexPath) else { return }
        collectionView.allowsSelection = false
        viewModel.didSelect(id)
    }
}

private extension Array {
    /// Index-path bounds outlive the snapshot that produced them; a supplementary
    /// configure can land after a section has gone away.
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
