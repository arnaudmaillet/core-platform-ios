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
/// # The header, and why it is not the one that was asked for
///
/// The ask was `[back][tab selector][the query]` in one row. A navigation
/// bar's `titleView` hosts ONE view, so the selector and the field cannot both
/// be in it, and the two ways out are both closed:
///
///   - putting the selector in the LEADING group kills the interactive pop —
///     `NativePopPolicy` refuses the edge gesture when a custom leading item
///     sits beside the back button and `leftItemsSupplementBackButton` is
///     false — and `ProfileRelationshipsViewController` records the measurement
///     that back + selector in one leading group collapses the whole group
///     into a `•••` on an iPhone SE.
///   - swapping them, which is what the relationships screen does, means the
///     query is invisible while the tabs are showing.
///
/// So the field keeps the title slot — it is the subject of the screen, and it
/// is what the viewer edits to ask again — and the selector takes the row
/// beneath it, which is what `PagedTabBar.floating` is documented for: "a
/// free-floating strip under the navigation bar, on the screen's own margins".
/// Same two controls, stacked, because UIKit will not put them side by side.
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

    private let tabBar = PagedTabBar(titles: ["Posts", "Media", "Users"], style: .floating)
    private var pager: HorizontalPagerView!

    private let peoplePage: SearchPeoplePage
    private let postsPage: UIViewController
    private let mediaPage: UIViewController

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
        viewModel.onPhaseChange = { [weak self] phase in self?.render(phase) }
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
        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchField.heightAnchor
            .constraint(equalToConstant: NavigationBarMetrics.itemPlatterHeight)
            .isActive = true
        navigationItem.titleView = searchField
    }

    // MARK: - Pages

    private func configurePages() {
        tabBar.translatesAutoresizingMaskIntoConstraints = false
        tabBar.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            self.pager.setActivePage(self.tabBar.selectedIndex, animated: true)
        }, for: .valueChanged)

        for page in [postsPage, mediaPage, peoplePage] {
            addChild(page)
            page.didMove(toParent: self)
        }
        pager = HorizontalPagerView(
            pages: [postsPage.view, mediaPage.view, peoplePage.view],
            initialIndex: 0
        )
        pager.translatesAutoresizingMaskIntoConstraints = false
        // ⚠️ The bar follows the SWIPE as well as the tap. A selector that only
        // moved on its own taps would sit on "Posts" while the viewer read the
        // gallery, which is the bug this channel exists to prevent.
        pager.onProgress = { [weak self] progress in self?.tabBar.setProgress(progress) }
        pager.onSettled = { [weak self] index in self?.tabBar.select(index) }

        view.addSubview(tabBar)
        view.addSubview(pager)
        NSLayoutConstraint.activate([
            tabBar.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 4),
            tabBar.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            tabBar.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),

            pager.topAnchor.constraint(equalTo: tabBar.bottomAnchor, constant: 8),
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
}

extension SearchResultsViewController: UITextFieldDelegate {
    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        viewModel.submitQuery(textField.text ?? "")
        textField.resignFirstResponder()
        return true
    }
}
