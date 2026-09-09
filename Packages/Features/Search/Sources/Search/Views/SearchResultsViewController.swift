import CoreModels
import DesignSystem
import MediaCore
import UIKit

/// A submitted search's answer, on its own screen.
///
/// # Why this is a screen and not a section
///
/// The answer used to be a third phase of the search screen's one collection
/// view — history, typeahead and results as sections of the same list. That
/// works while the answer is one kind. It stops working the moment the answer
/// is three: posts as cards, media as a grid, people as rows are three
/// LAYOUTS, and the search screen's list has exactly one.
///
/// # The header
///
/// `[back][selector][query]`, one row, the selector and the field splitting
/// what the back button leaves down the middle.
///
/// ⚠️ ONE VIEW IN THE TITLE SLOT — WHICH IS NOT THE SAME AS ONE CONTROL, and
/// getting that wrong cost this screen a revision. `navigationItem.titleView`
/// takes a single view, so the selector and the field cannot be two ITEMS; but
/// a view can contain both, and a composite in the title slot is one view by
/// UIKit's reckoning. The first build stacked them — field in the title,
/// selector on a floating strip beneath — on the conclusion that a row was
/// impossible. It was not.
///
/// ⚠️ THE LEADING GROUP IS STILL BARRED, and that part was right.
/// `NativePopPolicy` refuses the edge-swipe pop when a custom leading item sits
/// beside the back button and `leftItemsSupplementBackButton` is false, and
/// `ProfileRelationshipsViewController` records that back + selector in one
/// leading group collapses into a `•••` on an iPhone SE. The composite keeps
/// the leading group to the back button alone, so the pop survives.
///
/// ⚠️ THE SELECTOR SCROLLS WHEN IT DOES NOT FIT, and at half of a narrow bar it
/// often will not. That is `PagedTabBar`'s documented behaviour for a title
/// host — its minimums are required and the strip overflows and scrolls rather
/// than truncating a title, with `keepLensVisible` bringing the selected tab
/// back. Three tabs in ~150pt degrades by hiding a tab reachably instead of by
/// rendering an unreadable word.
///
/// # The three pages
///
/// Posts and Media are the same two surfaces For You's Following and Discover
/// tabs are, and they are NOT built here: they arrive as opaque child view
/// controllers through `SearchPostSurfaceProviding`, which the composition root
/// fills from Feed. That is the rule this codebase holds to — no feature
/// package imports another feature package, and `ForYouExploreAdapter` exists
/// for exactly this reason on exactly this screen's behalf.
@MainActor
final class SearchResultsViewController: UIViewController {
    private let viewModel: SearchViewModel
    private let imagePipeline: ImagePipeline
    private let postSurfaces: (any SearchPostSurfaceProviding)?

    /// The query, editable. Asking again from here re-runs in place rather than
    /// pushing a second copy of this screen — a stack of answers to successive
    /// spellings of one question is not something anyone wants to swipe back
    /// through.
    private let searchField = UISearchTextField()

    /// ⚠️ `.navigationTitle`, because it lives IN the bar now. That style is
    /// documented as "compact, marginless, and BARE: the navigation bar
    /// supplies the backdrop" — a `.floating` bar carries its own glass, which
    /// inside the bar's platter would draw a second lens over the first.
    private let tabBar = PagedTabBar(titles: ["Posts", "Media", "Users"], style: .navigationTitle)
    private var pager: HorizontalPagerView!

    private let peoplePage: SearchPeoplePage
    private let postsPage: any SearchPostSurface
    private let mediaPage: any SearchPostSurface

    init(
        viewModel: SearchViewModel,
        imagePipeline: ImagePipeline,
        postSurfaces: (any SearchPostSurfaceProviding)?
    ) {
        self.viewModel = viewModel
        self.imagePipeline = imagePipeline
        self.postSurfaces = postSurfaces
        peoplePage = SearchPeoplePage(imagePipeline: imagePipeline)
        postsPage = postSurfaces?.makePostSurface(style: .cards)
            ?? SearchPendingSurfaceViewController(kind: .posts)
        mediaPage = postSurfaces?.makePostSurface(style: .gallery)
            ?? SearchPendingSurfaceViewController(kind: .media)
        super.init(nibName: nil, bundle: nil)
        // ⚠️ IN THE INITIALISER. A navigation controller reads this when the
        // push BEGINS, and `viewDidLoad` can run inside that same push — set
        // there it is a coin toss whether the bar goes. The screen underneath
        // hides it too, so this only keeps it hidden rather than hiding it.
        hidesBottomBarWhenPushed = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        configureHeader()
        configurePages()
        configureToolbar()
        render(viewModel.currentPhase)
        showPosts(postState(for: viewModel.currentPhase))
        viewModel.onPhaseChange = { [weak self] phase in self?.render(phase) }
        viewModel.onPostResultsChange = { [weak self] _ in
            guard let self else { return }
            self.showPosts(self.postState(for: self.viewModel.currentPhase))
        }
        #if DEBUG
        // `-search-results-tab <0|1|2>` opens on a tab. The pager is driven by
        // a swipe and the simulator injects none, so without this only the
        // first tab can ever be seen offline.
        let arguments = ProcessInfo.processInfo.arguments
        if let index = arguments.firstIndex(of: "-search-results-tab"),
           index + 1 < arguments.count,
           let tab = Int(arguments[index + 1]), (0...2).contains(tab) {
            DispatchQueue.main.async { [weak self] in
                self?.tabBar.select(tab)
                self?.pager.setActivePage(tab, animated: false)
            }
        }
        // `-search-filters-open` raises the filter sheet. The tray is a toolbar
        // item and the simulator taps nothing, so without this the sheet has no
        // way to be seen offline.
        if arguments.contains("-search-filters-open") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                self?.presentFilters()
            }
        }
        #endif
    }

    // MARK: - Header

    private func configureHeader() {
        searchField.text = viewModel.submittedQueryText
        searchField.placeholder = "Search..."
        searchField.autocapitalizationType = .none
        searchField.autocorrectionType = .no
        searchField.returnKeyType = .search
        searchField.delegate = self

        tabBar.translatesAutoresizingMaskIntoConstraints = false
        searchField.translatesAutoresizingMaskIntoConstraints = false

        let row = UIStackView(arrangedSubviews: [tabBar, searchField])
        row.axis = .horizontal
        row.spacing = 8
        row.alignment = .center
        // ⚠️ HALVES, and stated as a constraint rather than as
        // `.fillEqually`. A stack's equal fill divides the space it is GIVEN,
        // and a title view is given whatever the bar has left over — which
        // UIKit decides after measuring intrinsic sizes. Tying the two widths
        // to each other makes the split hold at whatever width the bar lands
        // on, including when the field grows a clear button mid-edit.
        tabBar.widthAnchor.constraint(equalTo: searchField.widthAnchor).isActive = true
        NSLayoutConstraint.activate([
            tabBar.heightAnchor.constraint(
                equalToConstant: NavigationBarMetrics.itemPlatterHeight
            ),
            searchField.heightAnchor.constraint(
                equalToConstant: NavigationBarMetrics.itemPlatterHeight
            )
        ])
        navigationItem.titleView = row
    }

    // MARK: - Pages

    private func configurePages() {
        tabBar.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            self.pager.setActivePage(self.tabBar.selectedIndex, animated: true)
        }, for: .valueChanged)

        for page in [postsPage.viewController, mediaPage.viewController, peoplePage] {
            addChild(page)
            page.didMove(toParent: self)
        }
        pager = HorizontalPagerView(
            pages: [postsPage.viewController.view, mediaPage.viewController.view, peoplePage.view],
            initialIndex: 0
        )
        pager.translatesAutoresizingMaskIntoConstraints = false
        // ⚠️ The bar follows the SWIPE as well as the tap. A selector that only
        // moved on its own taps would sit on "Posts" while the viewer read the
        // gallery, which is the bug this channel exists to prevent.
        pager.onProgress = { [weak self] progress in self?.tabBar.setProgress(progress) }
        pager.onSettled = { [weak self] index in self?.tabBar.select(index) }

        view.addSubview(pager)
        NSLayoutConstraint.activate([
            pager.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            pager.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            pager.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            pager.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
    }

    // MARK: - Toolbar

    /// The filter tray, bottom-trailing, in the system toolbar.
    ///
    /// ⚠️ IT MOVED OUT OF THE NAVIGATION BAR, and the bar is why. That bar now
    /// carries a back button and a full-width field; a third item would take
    /// the width straight off the query the viewer is reading. The toolbar is
    /// empty on this screen and within thumb reach, which is where a control
    /// used mid-scroll belongs.
    private func configureToolbar() {
        let filter = UIBarButtonItem(
            image: UIImage(systemName: "line.3.horizontal.decrease"),
            primaryAction: UIAction { [weak self] _ in self?.presentFilters() }
        )
        filter.accessibilityLabel = "Filters"
        toolbarItems = [.flexibleSpace(), filter]
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        // ⚠️ SHOWN HERE AND HIDDEN ON THE WAY OUT, because a navigation
        // controller's toolbar is SHARED: left visible, it would follow the pop
        // back onto the search screen, which has no toolbar items and would
        // show an empty bar.
        navigationController?.setToolbarHidden(false, animated: animated)
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        guard isMovingFromParent else { return }
        navigationController?.setToolbarHidden(true, animated: animated)
    }

    private func presentFilters() {
        present(SearchFilterSheetViewController.inSheet(groups: viewModel.filterGroups()) {
            [weak self] group, option in
            self?.viewModel.applyFilter(group: group, option: option)
        }, animated: true)
    }

    // MARK: - Rendering

    private func render(_ phase: SearchViewModel.Phase) {
        switch phase {
        case .results(let models):
            peoplePage.render(.results(models))
        case .loading:
            peoplePage.render(.loading)
        case .empty(let query):
            peoplePage.render(.empty(query: query))
        case .failed(let message):
            peoplePage.render(.failed(message: message))
        case .explore, .suggesting:
            // Reached only if the viewer clears the field. The answer on screen
            // is the last one submitted; it stays until they ask again.
            break
        }
    }

    /// ⚠️ THE POST TABS ARE NOT THE PEOPLE TAB'S STATE. The two searches are
    /// separate round trips with separate answers, and they disagree often:
    /// "harbour" matches two posts and nobody at all. Deriving the post tabs
    /// from the people phase showed an empty Posts tab for exactly that query.
    ///
    /// The phase is still read for LOADING and FAILED, which are properties of
    /// the request rather than of either answer.
    private func postState(for phase: SearchViewModel.Phase) -> SearchPostSurfaceState {
        switch phase {
        case .loading where viewModel.postResults.isEmpty:
            .loading
        case .failed(let message):
            .failed(message: message)
        case .explore, .suggesting:
            .loading
        case .loading, .results, .empty:
            viewModel.postResults.isEmpty
                ? .empty(query: viewModel.submittedQueryText)
                : .posts(viewModel.postResults)
        }
    }

    /// ⚠️ THE TWO TABS GET DIFFERENT SETS. Posts is every match; Media is the
    /// subset with a picture. Handing the gallery the full set drew a blank
    /// tile per text post — filmed, a grid of empty rectangles among the
    /// photographs.
    private func showPosts(_ state: SearchPostSurfaceState) {
        postsPage.show(state)
        mediaPage.show(mediaState(from: state))
    }

    private func mediaState(from state: SearchPostSurfaceState) -> SearchPostSurfaceState {
        guard case .posts = state else { return state }
        let media = viewModel.mediaResults
        return media.isEmpty ? .empty(query: viewModel.submittedQueryText) : .posts(media)
    }
}

extension SearchResultsViewController: UITextFieldDelegate {
    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        viewModel.submitQuery(textField.text ?? "")
        textField.resignFirstResponder()
        return true
    }
}
