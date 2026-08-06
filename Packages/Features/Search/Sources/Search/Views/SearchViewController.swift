import CoreModels
import CoreStorage
import DesignSystem
import MediaCore
import UIKit

/// The Search tab.
///
/// **One collection view for all three phases.** The resting history, the
/// narrowing-as-you-type list and a submitted search's results are sections in
/// the same diffable data source, so moving between them is a snapshot diff
/// the rows animate through rather than a view being swapped underneath them.
///
/// ⚠️ **The search field is not in the navigation bar.** This screen is hosted
/// by a `UISearchTab`, and iOS renders that tab's field as a capsule in the
/// TAB BAR at the bottom of the screen — the navigation bar carries only the
/// title. Two things follow, and both are load-bearing below: the list runs
/// full-bleed so rows pass UNDER that capsule, with the last of them kept
/// reachable by a content inset rather than by a shorter frame (see
/// `updateBottomInsetForSearchField`); and the empty states ride
/// `keyboardLayoutGuide` so they centre in the space actually left over rather
/// than behind the keyboard.
final class SearchViewController: UIViewController {
    private let viewModel: SearchViewModel
    private let imagePipeline: ImagePipeline

    private let searchController = UISearchController(searchResultsController: nil)
    private var collectionView: UICollectionView!
    private let spinner = UIActivityIndicatorView(style: .medium)
    private let statusView = EmptyStateView()

    private var dataSource: UICollectionViewDiffableDataSource<SearchSection, SearchItem>!

    /// What the visible sections are, in order — the layout asks this by index
    /// for whether a section carries a header, and the header registration
    /// asks it for which section it is titling.
    private var visibleSections: [SearchSection] = []
    /// The rows currently on screen, by item. Cells read from here rather than
    /// from the phase, so a cell dequeued after a phase change still finds
    /// what it was asked to show.
    private var recentsByID: [String: SearchRowDisplayModel] = [:]
    private var resultsByID: [ProfileID: SearchResultDisplayModel] = [:]
    private var creatorsByID: [ProfileID: ExploreCreator] = [:]

    init(viewModel: SearchViewModel, imagePipeline: ImagePipeline) {
        self.viewModel = viewModel
        self.imagePipeline = imagePipeline
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Search"
        view.backgroundColor = .systemBackground
        configureSearchController()
        configureCollectionView()
        configureStatusViews()

        viewModel.onPhaseChange = { [weak self] phase in
            self?.render(phase)
        }
        viewModel.onQueryTextChange = { [weak self] text in
            // Recorded as already reported BEFORE the assignment: setting the
            // field re-enters `updateSearchResults`, and without this the
            // screen would narrow the history for the very query it is in the
            // middle of searching for.
            self?.lastReportedQuery = text
            self?.searchController.searchBar.text = text
        }
        viewModel.showExplore()

        #if DEBUG
        applyDebugArguments()
        #endif
    }

    // ⚠️ **No auto-focus, deliberately.** This screen used to claim the field
    // as first responder in `viewDidAppear`, which opened the keyboard on
    // arrival — and the keyboard covers roughly half the screen, so the two
    // sections the tab exists to show were mostly hidden behind it before the
    // viewer had done anything. The field is a tap away; the content is worth
    // seeing first.

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        // Only when something was PUSHED over this screen. A tab switch also
        // sends `viewWillDisappear`, and fading the bar for that would take it
        // away from whichever tab the viewer just moved to.
        guard navigationController?.topViewController !== self else { return }
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-search-layout-audit") { dumpBottomChrome() }
        #endif
        fadeTabBar(to: 0)
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        fadeTabBar(to: 1)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // Belt and braces: whatever the transition did or did not finish, a
        // screen that is on top must never leave invisible chrome behind it.
        tabBarChrome?.alpha = 1
    }

    /// The view holding the bottom chrome — the bar, its platters, and the
    /// search capsule.
    ///
    /// ⚠️ **Not `tabBarController.tabBar`.** On iOS 26 the tab-hosted search
    /// field is a SIBLING of the bar, not a child of it: the hierarchy is
    /// `_UITabBarContainerView` → { `UITabBar`, `_UITabHostedSearchContainer`,
    /// a loose platter }. Fading the bar was tried first and moved nothing on
    /// screen, because the capsule was never inside it. The container is the
    /// nearest view that holds all three.
    ///
    /// Reached by relationship rather than by class name, and guarded: if a
    /// future layout ever makes the bar a direct child of the controller's own
    /// view, fading that would fade the whole screen, so the bar itself is the
    /// fallback.
    private var tabBarChrome: UIView? {
        guard let tabBar = tabBarController?.tabBar else { return nil }
        guard let container = tabBar.superview, container !== tabBarController?.view else {
            return tabBar
        }
        return container
    }

    /// Fades the bottom chrome in step with the push or pop moving this screen.
    ///
    /// ⚠️ **The glitch this exists to fix.** `hidesBottomBarWhenPushed` takes
    /// the bar away at the END of the push, while its *contents* leave at the
    /// start — so for the whole transition two emptied glass containers sat
    /// frozen over the incoming profile and then popped out of existence.
    /// Riding the transition coordinator makes the glass leave with everything
    /// else, and come back the same way on the pop.
    ///
    /// Alpha rather than the house's usual render-level dissolve because the
    /// chrome is *leaving*, not restyling: the rule against fading a glass lens
    /// is about a material sampling the wrong backdrop while it stays on
    /// screen, and nothing here stays.
    private func fadeTabBar(to alpha: CGFloat) {
        guard let chrome = tabBarChrome else { return }
        guard let coordinator = transitionCoordinator else {
            chrome.alpha = alpha
            return
        }
        coordinator.animate(alongsideTransition: { _ in
            chrome.alpha = alpha
        }, completion: { context in
            // An interactive pop the viewer abandoned leaves the profile up, so
            // the chrome has to go back to where the push left it.
            if context.isCancelled { chrome.alpha = 1 - alpha }
        })
    }

    #if DEBUG
    /// `-search-layout-audit`: names every view sitting in the bottom band at
    /// push time. The search capsule is drawn by iOS somewhere in the tab bar's
    /// hierarchy and is not `tabBarController.tabBar`, so finding out what to
    /// animate means asking rather than assuming.
    private func dumpBottomChrome() {
        guard let window = view.window, let root = tabBarController?.view else { return }
        let band = window.bounds.height - 140
        func walk(_ view: UIView, depth: Int) {
            let frame = view.convert(view.bounds, to: window)
            if frame.maxY > band, frame.height > 8, frame.width > 40 {
                print(String(
                    format: "[chrome] %@%@ frame=%@ alpha=%.2f hidden=%@",
                    String(repeating: "  ", count: depth), String(describing: type(of: view)),
                    NSCoder.string(for: frame), view.alpha, view.isHidden ? "y" : "n"
                ))
            }
            view.subviews.forEach { walk($0, depth: depth + 1) }
        }
        walk(root, depth: 0)
    }
    #endif

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        updateBottomInsetForSearchField()
    }

    /// Keeps the last row reachable while the list runs full-bleed underneath
    /// the search field and the keyboard.
    ///
    /// **The field is not in this view hierarchy at all.** `UISearchTab`
    /// mirrors the search controller into a capsule it draws in the tab bar;
    /// `searchController.searchBar.window` is nil for the life of the screen,
    /// so the capsule's position cannot be measured — only its height, which
    /// the bar still reports because it is the object UIKit is mirroring.
    ///
    /// **This is the EXTRA inset, on top of the safe area.** The scroll view
    /// adjusts for the safe area by itself, and at rest the safe area already
    /// covers the tab-bar band the capsule is drawn in — so at rest the extra
    /// is zero, and rows scroll under the glass exactly as far as the safe
    /// area lets them come back out. Raise the keyboard and neither the safe
    /// area nor the guide accounts for the capsule any more: the guide stops
    /// at the top of the KEYBOARD, and the capsule floats above that. What is
    /// added is therefore the keyboard's own overhang past the resting bottom,
    /// plus the capsule sitting on top of it.
    private func updateBottomInsetForSearchField() {
        let restingBottom = view.bounds.height - view.safeAreaInsets.bottom
        let keyboardTop = view.keyboardLayoutGuide.layoutFrame.minY
        let keyboardIsUp = keyboardTop < restingBottom - 1
        let inset = keyboardIsUp
            ? (restingBottom - keyboardTop) + searchController.searchBar.bounds.height
            : 0
        // Guarded: assigning an inset lays out again, and an unguarded
        // assignment here would be a layout loop.
        guard abs(collectionView.contentInset.bottom - inset) > 0.5 else { return }
        collectionView.contentInset.bottom = inset
        collectionView.verticalScrollIndicatorInsets.bottom = inset
        #if DEBUG
        // `-search-layout-audit`: the numbers behind the reservation, since
        // "the field was accounted for" and "the guard bailed out and nothing
        // happened" look identical in a screenshot.
        if ProcessInfo.processInfo.arguments.contains("-search-layout-audit") {
            print(String(
                format: "[search-layout] kbTop=%.1f restingBottom=%.1f safeBottom=%.1f keyboardUp=%@ extraInset=%.1f adjusted=%.1f",
                keyboardTop, restingBottom, view.safeAreaInsets.bottom,
                keyboardIsUp ? "yes" : "no", inset, collectionView.adjustedContentInset.bottom
            ))
        }
        #endif
    }

    /// The last text the view model was told about.
    ///
    /// ⚠️ **`updateSearchResults` is not "the viewer typed".** UIKit also
    /// calls it when the field becomes or stops being first responder, and
    /// with auto-focus on, that lands right after a search has already
    /// returned: the results were replaced by the narrowed history a beat
    /// after arriving, for a query nobody re-typed. Comparing against what was
    /// last reported is what makes this a text-CHANGE callback.
    private var lastReportedQuery: String?

    // MARK: - Setup

    private func configureSearchController() {
        searchController.searchResultsUpdater = self
        searchController.searchBar.delegate = self
        // No dimming: the results land in THIS collection view, so there is
        // nothing above to obscure and a scrim would only grey out the answer.
        searchController.obscuresBackgroundDuringPresentation = false
        searchController.searchBar.placeholder = "Search people"
        searchController.searchBar.autocapitalizationType = .none
        searchController.searchBar.autocorrectionType = .no
        searchController.searchBar.returnKeyType = .search
        // Stated rather than inherited: clearing through the system glyph
        // routes back out via `updateSearchResults`, so an emptied field
        // restores the history by the same path typing narrowed it.
        searchController.searchBar.searchTextField.clearButtonMode = .whileEditing
        // The bar stays while the field is active. It is the only thing on
        // this screen that says which screen it is — the field lives in the
        // tab bar, so letting UIKit hide the navigation bar on activation left
        // the list running up under the status bar with nothing titling it,
        // and with auto-focus that is the state the screen OPENS in.
        searchController.hidesNavigationBarDuringPresentation = false
        navigationItem.searchController = searchController
        navigationItem.hidesSearchBarWhenScrolling = false
        definesPresentationContext = true
    }

    private func configureCollectionView() {
        let layout = ExploreLayout.make { [weak self] index in
            self?.visibleSections[safe: index]?.title != nil
        }
        collectionView = UICollectionView(frame: view.bounds, collectionViewLayout: layout)
        collectionView.delegate = self
        collectionView.keyboardDismissMode = .onDrag
        // ⚠️ **Full bleed, all four edges.** It used to end at
        // `keyboardLayoutGuide.top`, which at rest is the top of the tab bar —
        // so the list stopped in a hard line above the search capsule and the
        // glass had nothing passing under it. A floating bar is only floating
        // if content goes beneath it. What keeps the last row reachable is the
        // INSET, not a shorter frame — see `updateBottomInsetForSearchField`.
        collectionView.constrain(in: view) { parent in
            collectionView.topAnchor.constraint(equalTo: parent.topAnchor)
            collectionView.leadingAnchor.constraint(equalTo: parent.leadingAnchor)
            collectionView.trailingAnchor.constraint(equalTo: parent.trailingAnchor)
            collectionView.bottomAnchor.constraint(equalTo: parent.bottomAnchor)
        }

        // The SAME cell the Suggestions and results sections use. A remembered
        // person and a suggested person are the same person, and the screen
        // used to draw them differently — a 48pt avatar in one section and a
        // 22pt glyph in the other.
        let rowRegistration = UICollectionView.CellRegistration<PersonListCell, String> {
            [weak self] cell, _, id in
            guard let self, let model = self.recentsByID[id] else { return }
            // One rhythm across the screen: a one-line query row reserves the
            // same band as a two-line person row, so Recent does not read as a
            // denser list than Suggestions.
            cell.minimumRowHeight = PersonListCell.comfortableRowHeight
            cell.configure(
                with: model.rowContent,
                // Only the history is the viewer's to forget; a completion is
                // not remembered in the first place.
                onDelete: model.isRemovable ? { [weak self] in self?.viewModel.didDeleteRecent(id) } : nil
            )
            self.loadAvatar(model.avatarURL, into: cell, stillShowing: .row(id))
        }

        let seeMoreRegistration = UICollectionView.CellRegistration<SeeMoreCell, Int> {
            cell, _, hiddenCount in
            cell.configure(hiddenCount: hiddenCount)
        }

        let resultRegistration = UICollectionView.CellRegistration<PersonListCell, ProfileID> {
            [weak self] cell, _, id in
            guard let self, let model = self.resultsByID[id] else { return }
            cell.minimumRowHeight = PersonListCell.comfortableRowHeight
            cell.configure(with: model.rowContent)
            self.loadAvatar(model.avatarURL, into: cell, stillShowing: .result(id))
        }

        // The SAME row the results list uses, and the compose picker, and the
        // inbox's search. A creator and a search hit are both a person, and a
        // screen that drew them differently would be saying they are not.
        let suggestedRegistration = UICollectionView.CellRegistration<PersonListCell, ProfileID> {
            [weak self] cell, _, id in
            guard let self, let creator = self.creatorsByID[id] else { return }
            cell.minimumRowHeight = PersonListCell.comfortableRowHeight
            cell.configure(with: PersonRowContent(
                displayName: creator.displayName,
                handle: creator.handle,
                monogram: creator.monogram
            ))
            self.loadAvatar(creator.avatarURL, into: cell, stillShowing: .suggested(id))
        }

        let suggestedSkeletonRegistration =
            UICollectionView.CellRegistration<PersonSkeletonCell, Int> { cell, _, index in
                cell.configure(at: index)
            }

        // A plain list pins its headers, so rows pass DIRECTLY under this one.
        // The pill inside carries its own glass, and its clear background is
        // what lets the rows show through around it.
        let headerRegistration = UICollectionView.SupplementaryRegistration<ExploreSectionHeaderView>(
            elementKind: UICollectionView.elementKindSectionHeader
        ) { [weak self] header, _, indexPath in
            // Captured by SECTION, not by index path: the header is reused and
            // its index path is only valid for this configure pass, whereas
            // the section it names survives the snapshots that reshuffle rows
            // beneath it.
            let section = self?.visibleSections[safe: indexPath.section]
            header.configure(
                title: section?.title,
                actionTitle: section?.actionTitle,
                leadsList: indexPath.section == 0
            )
            header.onAction = { [weak self] in
                guard section == .recent else { return }
                self?.viewModel.didClearRecents()
            }
        }

        dataSource = UICollectionViewDiffableDataSource<SearchSection, SearchItem>(
            collectionView: collectionView
        ) { collectionView, indexPath, item in
            switch item {
            case .row(let id):
                collectionView.dequeueConfiguredReusableCell(
                    using: rowRegistration, for: indexPath, item: id
                )
            case .seeMoreRecents(let hiddenCount):
                collectionView.dequeueConfiguredReusableCell(
                    using: seeMoreRegistration, for: indexPath, item: hiddenCount
                )
            case .result(let id):
                collectionView.dequeueConfiguredReusableCell(
                    using: resultRegistration, for: indexPath, item: id
                )
            case .suggested(let id):
                collectionView.dequeueConfiguredReusableCell(
                    using: suggestedRegistration, for: indexPath, item: id
                )
            case .suggestedSkeleton(let index):
                collectionView.dequeueConfiguredReusableCell(
                    using: suggestedSkeletonRegistration, for: indexPath, item: index
                )
            }
        }
        dataSource.supplementaryViewProvider = { collectionView, _, indexPath in
            collectionView.dequeueConfiguredReusableSupplementary(
                using: headerRegistration, for: indexPath
            )
        }
    }

    /// Fills a creator row's disc, if the corpus carried a picture.
    ///
    /// Cache-first and synchronous when it can be: a warm avatar set inside
    /// the cell registration never shows the monogram at all, where an
    /// unconditional `Task` would flash initials for a frame on every scroll.
    ///
    /// The task is keyed by the row's own identity rather than held: cells are
    /// recycled, and by the time a slow load returns the cell may be showing
    /// someone else. Re-reading the item at completion is what keeps the wrong
    /// face off the right row.
    private func loadAvatar(_ url: URL?, into cell: PersonListCell, stillShowing item: SearchItem) {
        guard let url else { return }
        if let cached = imagePipeline.cachedImage(for: url) {
            return cell.setAvatarImage(cached)
        }
        Task { [weak self, weak cell] in
            guard let image = try? await self?.imagePipeline.image(for: url) else { return }
            guard let self, let cell,
                  let indexPath = self.collectionView.indexPath(for: cell),
                  self.dataSource.itemIdentifier(for: indexPath) == item
            else { return }
            cell.setAvatarImage(image)
        }
    }

    private func configureStatusViews() {
        spinner.hidesWhenStopped = true
        spinner.constrain(in: view) { parent in
            spinner.centerXAnchor.constraint(equalTo: parent.centerXAnchor)
            spinner.centerYAnchor.constraint(equalTo: parent.centerYAnchor)
        }

        statusView.isHidden = true
        // The same keyboard bound the list has: `EmptyStateView` centres its
        // column in whatever space it is given, and the space actually left
        // over is what it should centre in.
        statusView.constrain(in: view) { parent in
            statusView.topAnchor.constraint(equalTo: parent.safeAreaLayoutGuide.topAnchor)
            statusView.leadingAnchor.constraint(equalTo: parent.leadingAnchor)
            statusView.trailingAnchor.constraint(equalTo: parent.trailingAnchor)
            statusView.bottomAnchor.constraint(equalTo: parent.keyboardLayoutGuide.topAnchor)
        }
    }

    // MARK: - Render

    private func render(_ phase: SearchViewModel.Phase) {
        switch phase {
        case .explore(let model):
            spinner.stopAnimating()
            recentsByID = Dictionary(uniqueKeysWithValues: model.recents.map { ($0.id, $0) })
            creatorsByID = Dictionary(
                model.trending.creators.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }
            )
            apply(exploreSnapshot(model))
            if model.isEmpty {
                showStatus(
                    symbolName: "magnifyingglass",
                    title: "Search people",
                    subtitle: "Find people by name or @handle. What you search for shows up here."
                )
            } else {
                hideStatus()
            }

        case .suggesting(let query, let rows):
            spinner.stopAnimating()
            recentsByID = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })
            apply(suggestionsSnapshot(rows))
            if rows.isEmpty {
                // Not a failure, and the wording has to say so: nothing has
                // been searched for yet. This is also where the screen teaches
                // that searching is something you DO, since the flow is
                // submit-driven and nothing happens while you type.
                showStatus(
                    symbolName: "return",
                    title: "Press Search",
                    subtitle: "Search for “\(query)” to see people."
                )
            } else {
                hideStatus()
            }

        case .loading:
            spinner.startAnimating()
            hideStatus()

        case .results(let models):
            spinner.stopAnimating()
            hideStatus()
            resultsByID = Dictionary(uniqueKeysWithValues: models.map { ($0.id, $0) })
            apply(resultsSnapshot(models))

        case .empty(let query):
            spinner.stopAnimating()
            apply(NSDiffableDataSourceSnapshot<SearchSection, SearchItem>())
            showStatus(
                symbolName: "person.slash",
                title: "No people found",
                subtitle: "Nothing matched “\(query)”. Try a different name or handle."
            )

        case .failed(let message):
            spinner.stopAnimating()
            apply(NSDiffableDataSourceSnapshot<SearchSection, SearchItem>())
            showStatus(symbolName: "exclamationmark.triangle", title: "Couldn't search", subtitle: message)
        }
    }

    // MARK: - Snapshots

    private func exploreSnapshot(
        _ model: ExploreDisplayModel
    ) -> NSDiffableDataSourceSnapshot<SearchSection, SearchItem> {
        var snapshot = NSDiffableDataSourceSnapshot<SearchSection, SearchItem>()
        if !model.recents.isEmpty {
            snapshot.appendSections([.recent])
            snapshot.appendItems(model.recents.map { .row($0.id) }, toSection: .recent)
            if model.showsMoreRecentsRow {
                snapshot.appendItems([.seeMoreRecents(model.hiddenRecentCount)], toSection: .recent)
            }
        }

        switch model.trending {
        case .unavailable, .failed:
            // No section at all. A suggestions list that failed is not worth
            // a row of apology on a screen whose search still works.
            break
        case .loading:
            snapshot.appendSections([.suggestions])
            snapshot.appendItems(
                (0..<Self.suggestedSkeletonCount).map { .suggestedSkeleton($0) }, toSection: .suggestions
            )
        case .loaded(let creators):
            guard !creators.isEmpty else { break }
            snapshot.appendSections([.suggestions])
            snapshot.appendItems(creators.map { .suggested($0.id) }, toSection: .suggestions)
        }
        return snapshot
    }

    /// Enough rows to reach the fold, so the shimmer reads as "a list is
    /// coming" rather than as two stray bones.
    private static let suggestedSkeletonCount = 5

    private func suggestionsSnapshot(
        _ rows: [SearchRowDisplayModel]
    ) -> NSDiffableDataSourceSnapshot<SearchSection, SearchItem> {
        var snapshot = NSDiffableDataSourceSnapshot<SearchSection, SearchItem>()
        guard !rows.isEmpty else { return snapshot }
        snapshot.appendSections([.completions])
        snapshot.appendItems(rows.map { .row($0.id) }, toSection: .completions)
        return snapshot
    }

    private func resultsSnapshot(
        _ models: [SearchResultDisplayModel]
    ) -> NSDiffableDataSourceSnapshot<SearchSection, SearchItem> {
        var snapshot = NSDiffableDataSourceSnapshot<SearchSection, SearchItem>()
        guard !models.isEmpty else { return snapshot }
        snapshot.appendSections([.results])
        snapshot.appendItems(models.map { .result($0.id) }, toSection: .results)
        return snapshot
    }

    private func apply(_ snapshot: NSDiffableDataSourceSnapshot<SearchSection, SearchItem>) {
        var snapshot = snapshot
        // ⚠️ **A row whose ITEM is unchanged is not re-rendered.** Diffable
        // compares identifiers, and every identifier here is an id or a query
        // string — stable by design, because that is what makes the animations
        // right. So when an avatar resolves and the same people are re-emitted,
        // the diff is empty and the cells keep their initials forever: the
        // pictures were arriving and nothing was drawing them.
        //
        // `reconfigureItems` is the counterpart — same cell, run its
        // registration again. Only the rows that CARRY OVER need it; new ones
        // are configured on the way in.
        let carried = Set(dataSource.snapshot().itemIdentifiers)
        let surviving = snapshot.itemIdentifiers.filter(carried.contains)
        if !surviving.isEmpty { snapshot.reconfigureItems(surviving) }
        // Recorded BEFORE the apply. The layout's section provider and the
        // header registration both read this, and both run during the apply —
        // updating it afterwards would lay the new sections out against the
        // old list's answers.
        visibleSections = snapshot.sectionIdentifiers
        dataSource.apply(snapshot, animatingDifferences: true)
    }

    private func showStatus(symbolName: String, title: String, subtitle: String) {
        statusView.configure(symbolName: symbolName, title: title, subtitle: subtitle)
        statusView.isHidden = false
    }

    private func hideStatus() {
        statusView.isHidden = true
    }

    // MARK: - Debug

    #if DEBUG
    private func applyDebugArguments() {
        let arguments = ProcessInfo.processInfo.arguments
        // `-search-query <text>` seeds the field on launch, so the typing path
        // is testable without driving the keyboard.
        guard let index = arguments.firstIndex(of: "-search-query"), index + 1 < arguments.count
        else { return }
        let seeded = arguments[index + 1]
        lastReportedQuery = seeded
        searchController.searchBar.text = seeded
        viewModel.queryChanged(seeded)
        // `-search-submit`: also press Search. Seeding alone only types, and
        // typing deliberately searches nothing — so without this the results
        // and history paths have no way to run in-sim, where the Search key
        // cannot be tapped.
        if arguments.contains("-search-submit") {
            viewModel.submitQuery(seeded)
        }
    }
    #endif
}

extension SearchViewController: UISearchResultsUpdating {
    func updateSearchResults(for searchController: UISearchController) {
        let text = searchController.searchBar.text ?? ""
        guard text != lastReportedQuery else { return }
        lastReportedQuery = text
        viewModel.queryChanged(text)
    }
}

extension SearchViewController: UISearchBarDelegate {
    func searchBarSearchButtonClicked(_ searchBar: UISearchBar) {
        viewModel.submitQuery(searchBar.text ?? "")
        // The answer is what the viewer wants to look at now, and the keyboard
        // is the only thing still covering it.
        searchBar.resignFirstResponder()
    }
}

extension SearchViewController: UICollectionViewDelegate {
    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        guard let item = dataSource.itemIdentifier(for: indexPath) else { return }
        switch item {
        case .row(let id):
            viewModel.didSelectRow(id)
            searchController.searchBar.resignFirstResponder()
        case .seeMoreRecents:
            viewModel.didRequestMoreRecents()
        case .result(let id):
            viewModel.didSelectResult(id)
        case .suggested(let id):
            viewModel.didSelectCreator(id)
        case .suggestedSkeleton:
            break
        }
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
